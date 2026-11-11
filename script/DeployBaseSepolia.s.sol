// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/interfaces/IPayable.sol";

import { DemoVault } from "../src/DemoVault.sol";
import { Attacker } from "../src/Attacker.sol";
import { VaultGuardCallback } from "../src/VaultGuardCallback.sol";

/// @notice Deploys the Base Sepolia side of the ReactiveVaultGuard demo:
///         DemoVault (prefunded with fake TVL), Attacker, and - once the reactive guard
///         exists on Reactive Network - VaultGuardCallback wired as the vault pauser.
///         Env: GUARD_ADDRESS (Reactive Lasna address of ReactiveVaultGuard; if unset,
///         only vault + attacker deploy and the callback step is deferred).
contract DeployBaseSepolia is Script {
    /// @notice Real Base Sepolia Reactive callback proxy (dev.reactive.network).
    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    uint256 public constant VAULT_TVL = 0.03 ether;
    uint256 public constant ATTACKER_STAKE = 0.004 ether;
    uint256 public constant CALLBACK_FUND = 0.008 ether;

    function run() external returns (DemoVault vault, Attacker attacker, VaultGuardCallback callback) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        vault = new DemoVault{value: VAULT_TVL}();
        attacker = new Attacker{value: ATTACKER_STAKE}(vault);

        address guard = vm.envOr("GUARD_ADDRESS", address(0));
        if (guard != address(0)) {
            callback = new VaultGuardCallback{value: CALLBACK_FUND}(
                IPayable(payable(BASE_SEPOLIA_CALLBACK_PROXY)), guard, address(vault)
            );
            vault.setPauser(address(callback));
        }

        vm.stopBroadcast();

        console2.log("DemoVault:         ", address(vault));
        console2.log("Attacker:          ", address(attacker));
        if (address(callback) != address(0)) {
            console2.log("VaultGuardCallback:", address(callback));
            console2.log("vault.pauser:      ", vault.pauser());
        } else {
            console2.log("VaultGuardCallback: SKIPPED (set GUARD_ADDRESS to deploy)");
        }
    }
}
