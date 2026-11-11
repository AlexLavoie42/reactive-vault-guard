// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IPayable} from "@reactive/interfaces/IPayable.sol";

import {DemoVault} from "../src/DemoVault.sol";
import {VaultGuardCallback} from "../src/VaultGuardCallback.sol";

/// @notice Second Base Sepolia step, run after ReactiveVaultGuard exists on Lasna:
///         deploys VaultGuardCallback against the REAL Base Sepolia callback proxy,
///         hands it the vault pauser role, and funds it for callback delivery gas.
///         Env: VAULT_ADDRESS, GUARD_ADDRESS (Reactive Lasna).
contract WireBase is Script {
    address public constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    uint256 public constant CALLBACK_FUND = 0.008 ether;

    function run() external returns (VaultGuardCallback callback) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        DemoVault vault = DemoVault(vm.envAddress("VAULT_ADDRESS"));
        address guard = vm.envAddress("GUARD_ADDRESS");

        vm.startBroadcast(pk);

        callback = new VaultGuardCallback{value: CALLBACK_FUND}(
            IPayable(payable(BASE_SEPOLIA_CALLBACK_PROXY)), guard, address(vault)
        );
        vault.setPauser(address(callback));

        vm.stopBroadcast();

        console2.log("VaultGuardCallback:", address(callback));
        console2.log("vault.pauser:      ", vault.pauser());
    }
}
