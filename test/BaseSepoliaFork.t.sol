// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/interfaces/IPayable.sol";

import { DemoVault } from "../src/DemoVault.sol";
import { Attacker } from "../src/Attacker.sol";
import { ReactiveVaultGuard } from "../src/ReactiveVaultGuard.sol";
import { VaultGuardCallback } from "../src/VaultGuardCallback.sol";

/// @title BaseSepoliaFork - destination-chain side of the demo, executed against a real
///        Base Sepolia fork (run: forge test --match-contract BaseSepoliaForkTest
///        --fork-url https://sepolia.base.org).
/// @notice The Reactive side cannot be forked together with Base Sepolia, so the guard's
///         pause callback is delivered by pranking the REAL Base Sepolia callback proxy
///         (0x476F44b11F5C942C58f4C0e3d0300E5710743585) - the same address that would
///         deliver it live. Everything else (vault, storm, callback contract, pause,
///         follow-up revert) runs exactly as deployed.
contract BaseSepoliaForkTest is Test {
    /// @notice Real Base Sepolia Reactive callback proxy per dev.reactive.network
    ///         /origins-and-destinations.
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942C58f4C0e3d0300E5710743585;

    /// @notice Stand-in for the reactive contract's address on Reactive Network.
    address internal constant GUARD_STAND_IN = 0x00000000000000000000000000000000beEfCA11;

    DemoVault internal vault;
    VaultGuardCallback internal callback;
    Attacker internal attacker;

    function setUp() public {
        // Skip unless running against a real Base Sepolia fork
        // (forge test --match-contract BaseSepoliaForkTest --fork-url https://sepolia.base.org).
        if (block.chainid != 84_532) {
            vm.skip(true);
        }

        vm.deal(address(this), 5 ether);
        vault = new DemoVault{value: 1 ether}();
        callback = new VaultGuardCallback{value: 0.1 ether}(
            IPayable(payable(BASE_SEPOLIA_CALLBACK_PROXY)), GUARD_STAND_IN, address(vault)
        );
        vault.setPauser(address(callback));

        attacker = new Attacker{value: 0.2 ether}(vault);
        attacker.deposit{value: 0.1 ether}();
    }

    function testFork_StormDrainsAndGuardCallbackPausesVault() public {
        uint256 vaultBefore = address(vault).balance;

        // 1. The reentrancy storm drains the vulnerable vault on the real fork.
        attacker.attack(0.01 ether);
        assertLt(address(vault).balance, 0.02 ether, "vault must be drained to dust");
        assertGe(address(attacker).balance, vaultBefore - 0.02 ether, "attacker holds the loot");

        // 2. Pause callback as delivered by the REAL proxy, with the requester address
        //    (the reactive guard) in the reserved first argument.
        vm.prank(BASE_SEPOLIA_CALLBACK_PROXY);
        callback.onExploitDetected(GUARD_STAND_IN, 2, address(attacker), 0.01 ether, 0, uint256(keccak256("storm")));
        assertTrue(vault.paused(), "vault must be paused");

        // 3. The attacker's follow-up drain reverts on the circuit breaker.
        vm.expectRevert(DemoVault.EnforcedPause.selector);
        attacker.followUpWithdraw(0.01 ether);
    }

    function testFork_CallbackRejectedWhenNotFromProxy() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        callback.onExploitDetected(GUARD_STAND_IN, 2, address(attacker), 0.01 ether, 0, 0);
    }
}
