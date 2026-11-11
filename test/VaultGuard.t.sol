// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/interfaces/IPayable.sol";

import { DemoVault } from "../src/DemoVault.sol";
import { Attacker } from "../src/Attacker.sol";
import { ReactiveVaultGuard } from "../src/ReactiveVaultGuard.sol";
import { VaultGuardCallback } from "../src/VaultGuardCallback.sol";

/// @dev Mock of the Reactive Network system contract (0x8888...8888). Records
///      subscriptions and callback requests so tests can assert on them.
contract MockSystemContract {
    struct Sub {
        uint256 chainId;
        address contract_;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct Cb {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] public subs;
    Cb[] public cbs;

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_, uint256 topic2_, uint256 topic3_)
        external
    {
        subs.push(Sub(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        cbs.push(Cb(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function subsLength() external view returns (uint256) {
        return subs.length;
    }

    function cbsLength() external view returns (uint256) {
        return cbs.length;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @dev Mock callback proxy on the destination chain: just an address with code that
///      satisfies onlyServiceProvider checks.
contract MockCallbackProxy {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @dev Plain router that performs two LEGITIMATE withdrawals in one tx (credit strictly
///      decreasing). The guard must NOT fire on this pattern.
contract LegitRouter {
    DemoVault public immutable vault;

    constructor(DemoVault vault_) {
        vault = vault_;
    }

    function withdrawTwice(uint256 a, uint256 b) external {
        vault.withdraw(a);
        vault.withdraw(b);
    }

    receive() external payable {}
}

contract VaultGuardTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    DemoVault internal vault;
    ReactiveVaultGuard internal guard;
    VaultGuardCallback internal callback;
    MockSystemContract internal mockSystem;
    MockCallbackProxy internal mockProxy;

    address internal alice = makeAddr("alice"); // legitimate user
    address internal mallory = makeAddr("mallory"); // attacker EOA

    uint256 internal constant TOPIC0_WITHDRAWAL = 0x0373e649c2cd6407bd569d5c66304cce4b4977c361734b811045f83c7bfe8c8b;

    function setUp() public {
        mockSystem = new MockSystemContract();
        // Place the mock at the real system contract address so AbstractReactive's
        // constant SYSTEM binding hits it.
        vm.etch(SYSTEM_ADDR, address(mockSystem).code);

        vault = new DemoVault{value: 1 ether}();
        vm.deal(alice, 1 ether);

        guard = new ReactiveVaultGuard{value: 1 ether}(BASE_SEPOLIA, address(vault), TOPIC0_WITHDRAWAL);

        mockProxy = new MockCallbackProxy();
        callback = new VaultGuardCallback{value: 0.1 ether}(IPayable(payable(address(mockProxy))), address(guard), address(vault));

        vault.setPauser(address(callback));
        guard.setCallbackRecipient(address(callback));
    }

    // ------------------------------------------------------------------ //
    //                         LogRecord construction                      //
    // ------------------------------------------------------------------ //

    function _withdrawalLog(uint256 txHash_, uint256 blockNumber_, uint256 logIndex_, uint256 amount_, uint256 creditBefore_, uint256 balanceBefore_)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(vault),
            topic0: TOPIC0_WITHDRAWAL,
            topic1: uint256(uint160(mallory)),
            topic2: uint256(uint160(mallory)),
            topic3: 0,
            data: abi.encode(amount_, creditBefore_, balanceBefore_),
            blockNumber: blockNumber_,
            opCode: 3,
            blockHash: 0,
            txHash: txHash_,
            logIndex: logIndex_
        });
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM_ADDR);
        guard.react(log_);
    }

    // ------------------------------------------------------------------ //
    //                            Subscription                            //
    // ------------------------------------------------------------------ //

    function test_SubscribesToVaultWithdrawalsOnBaseSepolia() public {
        (uint256 chainId, address contract_, uint256 topic0,,,) = MockSystemContract(payable(SYSTEM_ADDR)).subs(0);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(contract_, address(vault));
        assertEq(topic0, TOPIC0_WITHDRAWAL);
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).subsLength(), 1);
    }

    // ------------------------------------------------------------------ //
    //                         RULE_DRAIN (rule 1)                        //
    // ------------------------------------------------------------------ //

    function test_RuleDrain_SingleLargeWithdrawalTriggersImmediately() public {
        // Mallory withdraws 0.9 of a 1.0 ether vault: amount >= 50% of pre-balance.
        vm.prank(SYSTEM_ADDR);
        guard.react(_withdrawalLog(0xA1, 100, 0, 0.9 ether, 0.9 ether, 1 ether));

        assertEq(guard.alertsLength(), 1);
        ReactiveVaultGuard.Alert memory a0 = guard.getAlert(0);
        uint8 ruleId = a0.ruleId;
        assertEq(ruleId, guard.RULE_DRAIN());
    }

    function test_RuleDrain_SmallWithdrawalDoesNotTrigger() public {
        vm.prank(SYSTEM_ADDR);
        guard.react(_withdrawalLog(0xA2, 100, 0, 0.01 ether, 0.5 ether, 1 ether));

        assertEq(guard.alertsLength(), 0);
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 0);
    }

    // ------------------------------------------------------------------ //
    //                        RULE_REENTRY (rule 2)                       //
    // ------------------------------------------------------------------ //

    function test_RuleReentry_FrozenCreditAcrossSameTxLogsTriggers() public {
        // Reentrancy storm signature: three logs, same txHash, creditBefore frozen.
        _react(_withdrawalLog(0xB1, 200, 0, 0.01 ether, 0.1 ether, 1 ether));
        assertEq(guard.alertsLength(), 0, "first log must not alert");

        _react(_withdrawalLog(0xB1, 200, 1, 0.01 ether, 0.1 ether, 0.99 ether));
        assertEq(guard.alertsLength(), 1, "second log with frozen credit must alert");

        ReactiveVaultGuard.Alert memory a0 = guard.getAlert(0);
        uint8 ruleId = a0.ruleId;
        assertEq(ruleId, guard.RULE_REENTRY());

        // Third log of the same storm: no duplicate alert or callback.
        _react(_withdrawalLog(0xB1, 200, 2, 0.01 ether, 0.1 ether, 0.98 ether));
        assertEq(guard.alertsLength(), 1);
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 1);
    }

    function test_RuleReentry_LegitSameTxBatchedWithdrawalsDoNotTrigger() public {
        // A router withdrawing twice in one tx with STRICTLY DECREASING credit is
        // legitimate: the vault updated accounting between interactions.
        _react(_withdrawalLog(0xC1, 300, 0, 0.1 ether, 0.5 ether, 1 ether));
        _react(_withdrawalLog(0xC1, 300, 1, 0.1 ether, 0.4 ether, 0.9 ether));

        assertEq(guard.alertsLength(), 0);
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 0);
    }

    function test_RuleReentry_DifferentTxsNeverTrigger() public {
        // Sequential withdrawals in separate txs, frozen-looking credit is impossible,
        // but even identical values must not alert across txs.
        _react(_withdrawalLog(0xD1, 400, 0, 0.01 ether, 0.1 ether, 1 ether));
        _react(_withdrawalLog(0xD2, 401, 0, 0.01 ether, 0.1 ether, 0.99 ether));

        assertEq(guard.alertsLength(), 0);
    }

    // ------------------------------------------------------------------ //
    //                        Callback + pause loop                       //
    // ------------------------------------------------------------------ //

    function test_TriggeredGuardPausesVaultThroughCallback() public {
        _react(_withdrawalLog(0xE1, 500, 0, 0.01 ether, 0.1 ether, 1 ether));
        _react(_withdrawalLog(0xE1, 500, 1, 0.01 ether, 0.1 ether, 0.99 ether));

        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 1);
        (uint256 cbChain, address cbRecipient, uint64 cbGas, bytes memory cbPayload) = MockSystemContract(payable(SYSTEM_ADDR)).cbs(0);
        assertEq(cbChain, BASE_SEPOLIA);
        assertEq(cbRecipient, address(callback));
        assertGe(cbGas, 100_000);

        // Deliver the callback as the network would: the proxy overwrites the first
        // payload argument (the reserved address placeholder) with the requester's
        // address, then calls the recipient.
        bytes memory injected = cbPayload;
        assertEq(injected.length, 4 + 32 * 6);
        bytes32 requester = bytes32(uint256(uint160(address(guard))));
        for (uint256 i = 0; i < 20; i++) {
            injected[16 + i] = requester[12 + i];
        }
        vm.prank(address(mockProxy));
        (bool ok,) = address(callback).call(injected);
        assertTrue(ok, "callback delivery must succeed");

        assertTrue(vault.paused(), "vault must be paused");

        // Follow-up withdrawal attempts must hit the circuit breaker.
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        vm.expectRevert(DemoVault.EnforcedPause.selector);
        vault.withdraw(0.01 ether);
    }

    // ------------------------------------------------------------------ //
    //                          Admin behaviour                           //
    // ------------------------------------------------------------------ //

    function test_KillSwitchDisarmsDetection() public {
        guard.setArmed(false);

        _react(_withdrawalLog(0xF1, 600, 0, 0.9 ether, 0.9 ether, 1 ether));

        assertEq(guard.alertsLength(), 0);
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 0);
    }

    function test_OnlySystemMayCallReact() public {
        vm.expectRevert();
        guard.react(_withdrawalLog(0xF2, 600, 0, 0.9 ether, 0.9 ether, 1 ether));
    }

    function test_ThresholdsAreAdjustable() public {
        guard.setThresholds(9_000, 3); // >=90% drain, 3rd frozen log
        _react(_withdrawalLog(0xF3, 700, 0, 0.5 ether, 0.5 ether, 1 ether));
        assertEq(guard.alertsLength(), 0, "50% must not trigger at 90% threshold");

        _react(_withdrawalLog(0xF4, 701, 0, 0.5 ether, 0.1 ether, 0.9 ether));
        _react(_withdrawalLog(0xF4, 701, 1, 0.01 ether, 0.1 ether, 0.9 ether));
        assertEq(guard.alertsLength(), 0, "2nd log must not alert at reentryLimit=3");
        _react(_withdrawalLog(0xF4, 701, 2, 0.01 ether, 0.1 ether, 0.89 ether));
        assertEq(guard.alertsLength(), 1, "3rd frozen log must alert at reentryLimit=3");
        _react(_withdrawalLog(0xF4, 701, 3, 0.01 ether, 0.1 ether, 0.88 ether));
        assertEq(guard.alertsLength(), 1, "no duplicate alert for the same tx");
    }

    // ------------------------------------------------------------------ //
    //                     Callback authorization                         //
    // ------------------------------------------------------------------ //

    function test_CallbackRejectsNonProxyCaller() public {
        vm.prank(mallory);
        vm.expectRevert();
        callback.onExploitDetected(address(guard), 1, mallory, 0.1 ether, 0, 0xE1);
    }

    function test_CallbackRejectsWrongReactiveSender() public {
        vm.prank(address(mockProxy));
        vm.expectRevert();
        callback.onExploitDetected(address(0xBEEF), 1, mallory, 0.1 ether, 0, 0xE1); // wrong sender
    }

    // ------------------------------------------------------------------ //
    //                     Vault + attacker behaviour                     //
    // ------------------------------------------------------------------ //

    function test_AttackerStormDrainsVulnerableVault() public {
        // Fund attacker with 0.1 ETH credit; vault holds 1 ETH total (from setUp).
        vm.deal(address(this), 2 ether);
        Attacker attacker = new Attacker{value: 0.1 ether}(vault);
        attacker.deposit{value: 0.1 ether}();

        uint256 vaultBefore = address(vault).balance;
        attacker.attack(0.01 ether);

        assertLt(address(vault).balance, 0.02 ether, "vault must be drained to dust");
        assertGe(address(attacker).balance, vaultBefore - 0.02 ether, "attacker must hold the loot");
    }

    function test_PausedVaultBlocksWithdrawals() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vault.deposit{value: 0.5 ether}();
        vm.stopPrank();

        vm.prank(address(callback));
        vault.pause("test");

        vm.prank(alice);
        vm.expectRevert(DemoVault.EnforcedPause.selector);
        vault.withdraw(0.1 ether);
    }
}
