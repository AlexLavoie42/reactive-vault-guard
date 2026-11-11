// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/interfaces/IReactive.sol";

import { DemoVault } from "../src/DemoVault.sol";
import { Attacker } from "../src/Attacker.sol";
import { ReactiveVaultGuard } from "../src/ReactiveVaultGuard.sol";
import { VaultGuardCallback } from "../src/VaultGuardCallback.sol";
import { MockSystemContract, MockCallbackProxy } from "./VaultGuard.t.sol";
import { IPayable } from "@reactive/interfaces/IPayable.sol";

/// @title FullLoop - end-to-end LOCAL simulation of the cross-chain guard pipeline.
/// @notice Nothing here talks to a network. The attacker storm runs against the real
///         DemoVault, the real emitted Withdrawal logs are captured with
///         vm.getRecordedLogs and replayed into ReactiveVaultGuard.react() exactly as
///         the Reactive Network would deliver them, the captured callback request is
///         delivered to VaultGuardCallback as the Base Sepolia proxy would, and the
///         vault must end up paused before the attacker's follow-up transaction.
contract FullLoopTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    DemoVault internal vault;
    ReactiveVaultGuard internal guard;
    VaultGuardCallback internal callback;
    MockCallbackProxy internal mockProxy;

    uint256 internal constant TOPIC0_WITHDRAWAL = 0x0373e649c2cd6407bd569d5c66304cce4b4977c361734b811045f83c7bfe8c8b;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);

        vault = new DemoVault{value: 1 ether}();
        guard = new ReactiveVaultGuard{value: 1 ether}(BASE_SEPOLIA, address(vault), TOPIC0_WITHDRAWAL);
        mockProxy = new MockCallbackProxy();
        callback = new VaultGuardCallback{value: 0.1 ether}(
            IPayable(payable(address(mockProxy))), address(guard), address(vault)
        );
        vault.setPauser(address(callback));
        guard.setCallbackRecipient(address(callback));
    }

    /// @dev Converts real emitted logs into IReactive.LogRecord the way the Reactive
    ///      Network delivers them (same chainId/contract/topics/data; one record per log).
    function _toLogRecords(Vm.Log[] memory logs_, uint256 txHash_) internal view returns (IReactive.LogRecord[] memory) {
        uint256 n = 0;
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].emitter == address(vault) && uint256(logs_[i].topics[0]) == TOPIC0_WITHDRAWAL) n++;
        }
        IReactive.LogRecord[] memory recs = new IReactive.LogRecord[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].emitter != address(vault) || uint256(logs_[i].topics[0]) != TOPIC0_WITHDRAWAL) continue;
            Vm.Log memory lg = logs_[i];
            recs[j] = IReactive.LogRecord({
                chainId: BASE_SEPOLIA,
                contractAddress: address(vault),
                topic0: uint256(lg.topics[0]),
                topic1: uint256(lg.topics[1]),
                topic2: uint256(lg.topics[2]),
                topic3: 0,
                data: lg.data,
                blockNumber: block.number,
                opCode: lg.topics.length,
                blockHash: 0,
                txHash: txHash_, // all storm logs share one source tx hash
                logIndex: i
            });
            j++;
        }
        return recs;
    }

    function _reactAll(IReactive.LogRecord[] memory recs_) internal {
        for (uint256 i = 0; i < recs_.length; i++) {
            vm.prank(SYSTEM_ADDR);
            guard.react(recs_[i]);
        }
    }

    function _deliverFirstCallback() internal returns (bool ok) {
        MockSystemContract sys = MockSystemContract(payable(SYSTEM_ADDR));
        uint256 n = sys.cbsLength();
        if (n == 0) return false;
        (,,, bytes memory payload) = sys.cbs(0);
        // Emulate the network: overwrite the reserved first argument (address placeholder)
        // with the reactive contract's address, then call from the proxy.
        bytes32 requester = bytes32(uint256(uint160(address(guard))));
        for (uint256 i = 0; i < 20; i++) {
            payload[16 + i] = requester[12 + i];
        }
        vm.prank(address(mockProxy));
        (ok,) = address(callback).call(payload);
    }

    function test_FullLoop_RealStormLogsPauseVaultBeforeFollowUp() public {
        // 1. Real attack: 1 ETH vault, attacker deposits 0.1 ETH credit, storms 0.01/chunk.
        vm.deal(address(this), 2 ether);
        Attacker attacker = new Attacker{value: 0.2 ether}(vault);
        attacker.deposit{value: 0.1 ether}();

        vm.recordLogs();
        attacker.attack(0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The storm must actually have drained the vault (the vulnerability is real).
        assertLt(address(vault).balance, 0.02 ether, "storm must drain the vulnerable vault");

        // 2. Feed the REAL logs to the guard, exactly as the Reactive Network would.
        uint256 stormTxHash = uint256(keccak256("storm tx"));
        IReactive.LogRecord[] memory recs = _toLogRecords(logs, stormTxHash);
        assertGt(recs.length, 10, "storm must emit many withdrawal logs");
        _reactAll(recs);

        // RULE_REENTRY must have fired exactly once for the storm.
        assertEq(guard.alertsLength(), 1);
        ReactiveVaultGuard.Alert memory alert = guard.getAlert(0);
        assertEq(alert.ruleId, guard.RULE_REENTRY());
        assertEq(alert.attacker, address(attacker));
        assertEq(alert.sourceTxHash, stormTxHash);

        // Exactly one pause callback requested.
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 1);

        // 3. Deliver the callback as the Base Sepolia proxy would.
        assertTrue(_deliverFirstCallback(), "callback delivery must succeed");
        assertTrue(vault.paused(), "vault must be paused");

        // 4. The attacker's follow-up drain transaction hits the circuit breaker.
        vm.expectRevert(DemoVault.EnforcedPause.selector);
        attacker.followUpWithdraw(0.01 ether);
    }

    function test_FullLoop_LegitUserDoesNotPauseVault() public {
        // A legitimate user's ordinary withdrawals in separate txs: no alert, no pause.
        address user = makeAddr("user");
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        vault.deposit{value: 0.5 ether}();
        vm.stopPrank();

        vm.recordLogs();
        vm.startPrank(user);
        vault.withdraw(0.1 ether);
        vm.stopPrank();
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        _reactAll(_toLogRecords(logs1, uint256(keccak256("legit tx 1"))));

        vm.recordLogs();
        vm.startPrank(user);
        vault.withdraw(0.1 ether);
        vm.stopPrank();
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        _reactAll(_toLogRecords(logs2, uint256(keccak256("legit tx 2"))));

        assertEq(guard.alertsLength(), 0, "legitimate withdrawals must never alert");
        assertEq(MockSystemContract(payable(SYSTEM_ADDR)).cbsLength(), 0);
        assertFalse(vault.paused());
    }
}
