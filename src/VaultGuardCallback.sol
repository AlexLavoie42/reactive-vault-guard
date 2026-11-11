// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/base/AbstractCallback.sol";
import {IPayable} from "@reactive/interfaces/IPayable.sol";

interface IDemoVault {
    function paused() external view returns (bool);
    function pause(string calldata reason) external;
}

/// @title VaultGuardCallback - receives Reactive Network callbacks on Base Sepolia and
///        trips the vault's circuit breaker.
/// @notice Deployed on Base Sepolia (chain 84532) and called by the Reactive callback
///         proxy. It authenticates the callback (onlyServiceProvider + onlyCallbackSender)
///         and pauses the monitored vault. Holds the vault's pauser role and must be
///         funded with a small amount of native ETH to pay for callback delivery
///         (billed in the destination chain's native token).
contract VaultGuardCallback is AbstractCallback {
    event VaultPausedByGuard(
        address indexed reactive, uint256 indexed alertId, uint8 ruleId, address indexed attacker, uint256 amount
    );
    event VaultAlreadyPaused(address indexed reactive, uint256 indexed alertId, uint8 ruleId);

    IDemoVault public immutable vault;

    /// @param callbackProxy_ Base Sepolia callback proxy (0x476F44b11F5C942c58f4c0E3d0300E5710743585)
    /// @param callbackSender_ address of ReactiveVaultGuard on Reactive Network (immutable, unrecoverable if wrong)
    /// @param vault_ address of DemoVault on Base Sepolia; this contract must be its pauser
    constructor(IPayable callbackProxy_, address callbackSender_, address vault_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        vault = IDemoVault(vault_);
    }

    /// @notice Pause entry point. First argument is the address placeholder overwritten
    ///         by the network with the reactive contract's address.
    /// @dev Only the callback proxy may call, and only for the configured reactive sender.
    function onExploitDetected(
        address reactive_,
        uint8 ruleId,
        address attacker,
        uint256 amount,
        uint256 alertId,
        uint256 sourceTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        // sourceTxHash stays in calldata for gas; the authoritative evidence lives in the
        // ExploitDetected event on Reactive Network, cross-referenced by alertId.
        sourceTxHash;
        if (!vault.paused()) {
            emit VaultPausedByGuard(reactive_, alertId, ruleId, attacker, amount);
            vault.pause("ReactiveVaultGuard: exploit-shaped pattern detected");
        } else {
            emit VaultAlreadyPaused(reactive_, alertId, ruleId);
        }
    }

    /// @notice Debt settlement for the callback proxy, per docs.
    function coverDebt() external {
        _coverDebt();
    }
}
