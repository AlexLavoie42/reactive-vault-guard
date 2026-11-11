// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/base/AbstractReactive.sol";
import { IReactive } from "@reactive/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/interfaces/ISystemContract.sol";

/// @title ReactiveVaultGuard - reactive security watchdog running on Reactive Network
///        (Lasna testnet, chain 5318007).
/// @notice Subscribes to DemoVault.Withdrawal events on Base Sepolia (chain 84532) through
///         the system contract, classifies each log against onchain exploit-shape detectors
///         distilled from our security-review playbook (value-flow anomalies, reentrancy
///         windows, CEI violations), and - on the first trigger - requests a callback to
///         VaultGuardCallback on Base Sepolia which pauses the vault.
///
///  Detector library (rule ids):
///   - RULE_DRAIN   (1): value-flow anomaly - a single withdrawal that takes at least
///                        `drainBps` basis points of the vault balance observed before the
///                        withdrawal (default 50%). Legitimate user exits are small relative
///                        to TVL; a withdrawal that leaves less than it takes is drain-shaped.
///   - RULE_REENTRY (2): CEI violation - two or more Withdrawal logs in the SAME transaction
///                        from the same caller whose reported callerCreditBefore did not
///                        strictly decrease. A correct vault decreases credit on every
///                        withdrawal; frozen credit across same-tx withdrawals proves the
///                        accounting was not updated between interactions, i.e. an
///                        in-flight reentrancy loop.
///
///  Detection is non-reverting (reverting in react() is still billed and drops the signal):
///  on trigger we record an alert, emit ExploitDetected on Reactive Network (Reactscan
///  evidence), and request exactly one pause callback per source transaction.
contract ReactiveVaultGuard is AbstractReactive {
    // ------------------------------------------------------------------ //
    //                            Rule library                            //
    // ------------------------------------------------------------------ //

    uint8 public constant RULE_DRAIN = 1;
    uint8 public constant RULE_REENTRY = 2;

    /// @notice keccak256("Withdrawal(address,address,uint256,uint256,uint256)") - DemoVault.Withdrawal
    uint256 public constant WITHDRAWAL_TOPIC = 0x0373e649c2cd6407bd569d5c66304cce4b4977c361734b811045f83c7bfe8c8b;

    uint256 private constant BPS_DENOM = 10_000;

    // ------------------------------------------------------------------ //
    //                              Config                                //
    // ------------------------------------------------------------------ //

    uint256 public immutable monitoredChainId;
    address public immutable monitoredVault;
    uint64 public callbackGasLimit = 400_000;

    /// @notice Recipient of pause callbacks on the destination chain. Set post-deploy
    ///         (circular dependency: the callback needs this contract's address).
    address public callbackRecipient;

    /// @notice Kill switch: owner can disarm detection (e.g. during maintenance).
    bool public armed = true;

    uint256 public drainBps = 5_000; // >= 50% of pre-withdrawal balance => drain-shaped
    uint256 public reentryLimit = 2; // 2nd same-tx withdrawal with frozen credit => CEI violation

    address public owner;
    address public pendingOwner;

    // ------------------------------------------------------------------ //
    //                              State                                 //
    // ------------------------------------------------------------------ //

    struct TxBucket {
        uint128 count; // withdrawals seen so far in this source tx
        bool alerted; // one pause request per source tx
        uint256 creditBeforeFirst; // callerCreditBefore from the first log of this tx
        uint256 cumulative;
    }

    struct Alert {
        uint8 ruleId;
        address attacker;
        uint256 amount;
        uint256 evidence; // rule-specific: vaultBalanceBefore (DRAIN) or creditBefore (REENTRY)
        uint256 sourceChainId;
        uint256 sourceBlockNumber;
        uint256 sourceTxHash;
        uint64 reactBlockTimestamp; // Lasna block timestamp when classified
    }

    /// @dev txHash => caller => bucket. Keyed by caller so multi-user txs (rare, router
    ///      sweeps) do not alias; frozen-credit rule is still evaluated per caller.
    mapping(uint256 => mapping(address => TxBucket)) internal _txBuckets;

    Alert[] internal _alerts;

    // ------------------------------------------------------------------ //
    //                              Events                                //
    // ------------------------------------------------------------------ //

    event ExploitDetected(
        uint256 indexed alertId,
        uint8 indexed ruleId,
        address indexed attacker,
        uint256 amount,
        uint256 evidence,
        uint256 sourceChainId,
        uint256 sourceBlockNumber,
        uint256 sourceTxHash,
        uint64 reactBlockTimestamp
    );
    event CallbackRecipientSet(address recipient);
    event Armed(bool armed);
    event ThresholdsSet(uint256 drainBps, uint256 reentryLimit);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner(address caller, address owner);
    error ZeroAddress();
    event CallbackGasLimitSet(uint64 gasLimit);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner(msg.sender, owner);
        _;
    }

    // ------------------------------------------------------------------ //
    //                            Constructor                             //
    // ------------------------------------------------------------------ //

    /// @param monitoredChainId_ chain id of the watched vault (Base Sepolia = 84532)
    /// @param monitoredVault_ address of the watched DemoVault
    /// @param topic0_ Withdrawal event topic0 (passed in so tests and deploy scripts share one source of truth)
    constructor(uint256 monitoredChainId_, address monitoredVault_, uint256 topic0_) payable {
        require(topic0_ != 0, "topic0 required");
        owner = msg.sender;

        monitoredChainId = monitoredChainId_;
        monitoredVault = monitoredVault_;

        SYSTEM.subscribe(monitoredChainId_, monitoredVault_, topic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ------------------------------------------------------------------ //
    //                          Core reactive loop                        //
    // ------------------------------------------------------------------ //

    /// @notice Called by the system contract for every matching Withdrawal log.
    /// @dev Never reverts as a filter: a revert is billed and the log is dropped. All
    ///      classification failures degrade to "no alert" instead of reverting.
    function react(LogRecord calldata log_) external onlySystem {
        if (!armed) return;
        if (log_.chainId != monitoredChainId || log_.contractAddress != monitoredVault) return;
        if (log_.opCode != 3) return; // Withdrawal has 3 indexed topics

        (uint256 amount, uint256 creditBefore, uint256 balanceBefore) =
            abi.decode(log_.data, (uint256, uint256, uint256));

        address caller = address(uint160(log_.topic1));
        TxBucket storage bucket = _txBuckets[log_.txHash][caller];
        bucket.count += 1;
        bucket.cumulative += amount;

        // RULE_DRAIN: withdrawal amount >= drainBps/10_000 of the pre-withdrawal balance.
        // balanceBefore >= amount always holds on a solvent vault, so this is a strict
        // ratio test against TVL, not against the caller's own credit.
        if (balanceBefore > 0 && amount >= (balanceBefore * drainBps) / BPS_DENOM) {
            _alert(RULE_DRAIN, caller, amount, balanceBefore, log_);
        }

        // RULE_REENTRY: same-tx repeated withdrawal with non-decreasing credit.
        // First log of the tx records the baseline credit; any later log in the same tx
        // that does not show a STRICTLY smaller credit proves the credit was not updated
        // between interactions (CEI violation / reentrancy window).
        if (bucket.count == 1) {
            bucket.creditBeforeFirst = creditBefore;
        } else if (bucket.count >= reentryLimit && creditBefore >= bucket.creditBeforeFirst) {
            _alert(RULE_REENTRY, caller, amount, creditBefore, log_);
        }
    }

    /// @dev Records the alert, emits evidence on Reactive Network, and requests one pause
    ///      callback on the destination chain for this source tx. First trigger per
    ///      (source tx, caller) wins; later logs of the same storm are counted in the
    ///      bucket but do not spam alerts or callbacks.
    function _alert(uint8 ruleId_, address attacker_, uint256 amount_, uint256 evidence_, LogRecord calldata log_)
        internal
    {
        TxBucket storage bucket = _txBuckets[log_.txHash][attacker_];
        if (bucket.alerted) return;
        bucket.alerted = true;

        _alerts.push(
            Alert({
                ruleId: ruleId_,
                attacker: attacker_,
                amount: amount_,
                evidence: evidence_,
                sourceChainId: log_.chainId,
                sourceBlockNumber: log_.blockNumber,
                sourceTxHash: log_.txHash,
                reactBlockTimestamp: uint64(block.timestamp)
            })
        );
        uint256 alertId = _alerts.length - 1;

        emit ExploitDetected(
            alertId,
            ruleId_,
            attacker_,
            amount_,
            evidence_,
            log_.chainId,
            log_.blockNumber,
            log_.txHash,
            uint64(block.timestamp)
        );

        // Exactly one pause request per source transaction (guarded above).
        if (callbackRecipient != address(0)) {
            // First payload argument is the address placeholder the network overwrites
            // with this contract's address so the recipient can authenticate us.
            bytes memory payload = abi.encodeWithSignature(
                "onExploitDetected(address,uint8,address,uint256,uint256,uint256)",
                address(0),
                ruleId_,
                attacker_,
                amount_,
                alertId,
                log_.txHash
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: monitoredChainId,
                    recipient: callbackRecipient,
                    gasLimit: callbackGasLimit,
                    payload: payload
                })
            );
        }
    }

    // ------------------------------------------------------------------ //
    //                          Admin / owner                             //
    // ------------------------------------------------------------------ //

    function setCallbackRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        callbackRecipient = recipient_;
        emit CallbackRecipientSet(recipient_);
    }

    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        callbackGasLimit = gasLimit_;
        emit CallbackGasLimitSet(gasLimit_);
    }

    function setThresholds(uint256 drainBps_, uint256 reentryLimit_) external onlyOwner {
        require(drainBps_ > 0 && drainBps_ <= BPS_DENOM, "drainBps out of range");
        require(reentryLimit_ >= 2 && reentryLimit_ <= 50, "reentryLimit out of range");
        drainBps = drainBps_;
        reentryLimit = reentryLimit_;
        emit ThresholdsSet(drainBps_, reentryLimit_);
    }

    function setArmed(bool armed_) external onlyOwner {
        armed = armed_;
        emit Armed(armed_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferStarted(owner, newOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyOwner(msg.sender, owner);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ //
    //                              Views                                 //
    // ------------------------------------------------------------------ //

    function alertsLength() external view returns (uint256) {
        return _alerts.length;
    }

    function getAlert(uint256 index_) external view returns (Alert memory) {
        return _alerts[index_];
    }

    function txBucket(uint256 txHash_, address caller_) external view returns (TxBucket memory) {
        return _txBuckets[txHash_][caller_];
    }

    /// @notice Debt settlement per docs: a contract in debt receives nothing. Owner-callable.
    function coverDebt() external {
        _coverDebt();
    }
}
