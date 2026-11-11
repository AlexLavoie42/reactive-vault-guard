// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";

import { DemoVault } from "../src/DemoVault.sol";
import { Attacker } from "../src/Attacker.sol";

/// @notice Live demo driver (Base Sepolia): funds the attacker, runs the reentrancy
///         storm, polls until the Reactive pause callback lands, then attempts the
///         attacker's follow-up withdrawal. Prints everything the evidence file needs,
///         including the storm tx hash and the measured pause latency.
///         Env: VAULT_ADDRESS, ATTACKER_ADDRESS, CHUNK (optional, default 0.001 ether),
///              DEPOSIT (optional, default 0.01 ether), WAIT_SECONDS (default 90).
contract AttackDemo is Script {
    DemoVault public constant ERROR_SENTINEL = DemoVault(payable(address(1)));

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        DemoVault vault = DemoVault(vm.envAddress("VAULT_ADDRESS"));
        Attacker attacker = Attacker(payable(vm.envAddress("ATTACKER_ADDRESS")));
        uint256 chunk = vm.envOr("CHUNK", uint256(0.001 ether));
        uint256 deposit = vm.envOr("DEPOSIT", uint256(0.01 ether));
        uint256 wait = vm.envOr("WAIT_SECONDS", uint256(90));

        vm.startBroadcast(pk);

        console2.log("vault:             ", address(vault));
        console2.log("attacker:          ", address(attacker));
        console2.log("vault TVL before:  ", address(vault).balance);
        console2.log("vault paused:      ", vault.paused());

        // 1. Attacker builds legitimate credit.
        attacker.deposit{value: deposit}();
        console2.log("attacker deposited ", deposit);
        console2.log("vault TVL now:     ", address(vault).balance);

        // 2. The storm. vm.getBlockTimestamp gives wall-clock-ish test time; the real
        //    timestamps come from chain blocks and are recorded separately via cast.
        uint256 t0 = block.timestamp;
        attacker.attack(chunk);
        console2.log("STORM EXECUTED at unix", t0);
        console2.log("vault TVL after storm:", address(vault).balance);
        console2.log("attacker loot:      ", address(attacker).balance);

        // 3. Poll for the cross-chain pause callback (Reactive: event -> react() ->
        //    callback -> pause). Every second counts, so we poll tightly.
        uint256 start = block.timestamp;
        while (!vault.paused() && block.timestamp < start + wait) {
            vm.sleep(1000); // sleep 1s between polls
            if (address(vault).balance == type(uint256).max) break; // never
        }
        if (vault.paused()) {
            console2.log("VAULT PAUSED by Reactive callback after (s):", block.timestamp - start);
        } else {
            console2.log("vault NOT paused after waiting (s):", block.timestamp - start);
        }

        // 4. Follow-up drain attempt: the guard's whole point is that this fails.
        try attacker.followUpWithdraw(chunk) {
            console2.log("FOLLOW-UP SUCCEEDED - GUARD FAILED");
        } catch (bytes memory reason) {
            console2.log("FOLLOW-UP REVERTED - GUARD HELD THE LINE");
            console2.logBytes(reason);
        }

        console2.log("vault TVL final:   ", address(vault).balance);
        vm.stopBroadcast();
    }
}
