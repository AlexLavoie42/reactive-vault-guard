// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title DemoVault - DELIBERATELY VULNERABLE vault deployed on Base Sepolia for the demo.
/// @notice DO NOT USE WITH REAL FUNDS. The withdraw() function intentionally violates
///         Checks-Effects-Interactions: it emits its pre-state event, performs the external
///         call, and only then updates accounting inside `unchecked`, so a reentrant caller
///         can draw funds against a stale credit balance.
/// @dev The pre-state Withdrawal event is the observable signal ReactiveVaultGuard
///      subscribes to on Reactive Network. It carries enough data (amount, credit BEFORE
///      the interaction, vault balance BEFORE the interaction) for onchain exploit-shape
///      detection: a correct implementation shows callerCreditBefore strictly decreasing
///      across withdrawals in the same tx; a frozen (non-decreasing) callerCreditBefore
///      across two same-tx withdrawals is a CEI violation, i.e. an in-flight reentrancy.
contract DemoVault {
    event Deposit(address indexed sender, uint256 amount, uint256 senderCreditAfter, uint256 vaultBalanceAfter);
    event Withdrawal(
        address indexed caller,
        address indexed to,
        uint256 amount,
        uint256 callerCreditBefore,
        uint256 vaultBalanceBefore
    );
    event Paused(address indexed by, string reason);

    error EnforcedPause();
    error NotPauser(address caller, address pauser);

    address public pauser;
    bool public paused;

    mapping(address => uint256) public credits;

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    modifier onlyPauser() {
        if (msg.sender != pauser) revert NotPauser(msg.sender, pauser);
        _;
    }

    constructor() payable {
        pauser = msg.sender;
    }

    function deposit() external payable whenNotPaused {
        credits[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value, credits[msg.sender], address(this).balance);
    }

    /// @notice VULNERABLE (demo-only): interaction happens before the credit update, and the
    ///         update is `unchecked` (gas-golfing bug class). Reentrant calls read a stale
    ///         credit balance and the accounting underflows silently once the storm unwinds.
    function withdraw(uint256 amount) external whenNotPaused {
        uint256 credit = credits[msg.sender];
        if (credit < amount) revert("insufficient credit");

        // Pre-state signal: emitted before the external interaction so the reactive
        // network sees the earliest possible evidence ("Every Second Counts").
        emit Withdrawal(msg.sender, msg.sender, amount, credit, address(this).balance);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert("eth transfer failed");

        unchecked {
            credits[msg.sender] = credit - amount;
        }
    }

    /// @notice Circuit breaker, callable by the pauser (the VaultGuardCallback contract).
    function pause(string calldata reason) external onlyPauser {
        paused = true;
        emit Paused(msg.sender, reason);
    }

    function setPauser(address newPauser) external onlyPauser {
        pauser = newPauser;
    }

    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }
}
