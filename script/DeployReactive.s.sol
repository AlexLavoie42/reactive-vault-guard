// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";

import {ReactiveVaultGuard} from "../src/ReactiveVaultGuard.sol";

/// @notice Deploys ReactiveVaultGuard on Reactive Network (Lasna testnet, chain 5318007)
///         subscribed to DemoVault.Withdrawal on Base Sepolia (chain 84532).
///         Env: VAULT_ADDRESS (Base Sepolia address of DemoVault),
///              CALLBACK_ADDRESS (optional Base Sepolia VaultGuardCallback to receive
///              pause callbacks; if set, wired via setCallbackRecipient).
contract DeployReactive is Script {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    function run() external returns (ReactiveVaultGuard guard) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("VAULT_ADDRESS");
        address callback = vm.envOr("CALLBACK_ADDRESS", address(0));

        vm.startBroadcast(pk);

        // Float must cover one full react() billing per matching log. A reentrancy
        // storm emits one Withdrawal log per reentry frame (~0.005 REACT billed per
        // react() on Lasna, measured 2026-11-09); 0.4 ether covers a ~60-log storm.
        guard = new ReactiveVaultGuard{value: 0.4 ether}(
            BASE_SEPOLIA_CHAIN_ID,
            vault,
            0x0373e649c2cd6407bd569d5c66304cce4b4977c361734b811045f83c7bfe8c8b // DemoVault.Withdrawal topic0
        );
        if (callback != address(0)) {
            guard.setCallbackRecipient(callback);
        }

        vm.stopBroadcast();

        console2.log("ReactiveVaultGuard:", address(guard));
        console2.log("monitored chainId: ", guard.monitoredChainId());
        console2.log("monitored vault:   ", guard.monitoredVault());
        console2.log("callback recipient:", guard.callbackRecipient());
        console2.log("guard balance:     ", address(guard).balance);
    }
}
