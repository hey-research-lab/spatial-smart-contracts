// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRiskConfig} from "./interfaces/IRiskConfig.sol";
import {LoanTypes} from "./libraries/LoanTypes.sol";

/// @title RiskConfig
/// @notice Home of every adjustable protocol parameter. Changes pass through a timelock, and each one is
///         announced with an event.
/// @dev The flow is: governance queues a batch with `schedule(calls, salt, rationale)`, waits `delay` seconds,
///      and then has a grace window in which `execute(calls, salt)` can run it. Execution works by calling each
///      setter on this contract from the contract itself, and the `onlyTimelocked` modifier admits nothing else,
///      except that the owner may call setters directly until `finishBootstrap()` is called, after which that
///      route is closed for good. The guardian can halt new loans and liquidations but has no power to lift a
///      halt. The risk config never holds or transfers tokens, and none of its settings can stop a borrower from
///      repaying.
contract RiskConfig is IRiskConfig {
    /// @dev A queued batch, stored under its `operationId`. `rationale` is an arbitrary hash chosen by the
    ///      proposer and is not interpreted here.
    struct Operation {
        uint64 eta;
        bool executed;
        bool cancelled;
        bytes32 rationale;
    }

    /// @notice Lifecycle stage of a batch, as returned by `operationState`.
    enum OperationState {
        Unknown,
        Waiting,
        Ready,
        Stale,
        Executed,
        Cancelled
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS AND TIMELOCK
    //////////////////////////////////////////////////////////////*/

    address public override owner;
    address public override guardian;
    /// @notice Account that has been offered ownership and has yet to accept it.
    address public pendingOwner;
    /// @notice Minimum wait, in seconds, between queuing a batch and running it.
    uint256 public delay;
    /// @notice Length of the window after the delay during which a batch can still be run. Once it closes the
    ///         batch is dead and must be queued again with a different salt.
    /// @dev Deliberately a constant. If governance could lengthen the window, it could lengthen it to keep alive
    ///      a batch that is being held back for a convenient moment.
    uint256 public constant GRACE_PERIOD = 14 days;
    /// @notice Set once bootstrap has ended, after which setters only accept calls coming from the timelock.
    bool public bootstrapped;

    mapping(bytes32 => Operation) public operations;

    /*//////////////////////////////////////////////////////////////
                              PARAMETERS
    //////////////////////////////////////////////////////////////*/

    mapping(uint8 => TierConfig) internal _tiers;
    mapping(address => TokenConfig) internal _tokens;
    mapping(address => bool) public override loanTokenEnabled;
    mapping(uint32 => bool) public override termAllowed;
    mapping(address => bool) public override vaultWhitelisted;
    mapping(address => bool) public override attestationIssuer;
    address public override eligibilityAdapter;
    bool public override newLoansPaused;
    bool public override liquidationsPaused;

    LoanParams internal _loanParams;
    AuctionParams internal _auctionParams;
    RefinanceParams internal _refinanceParams;
    FeeParams internal _feeParams;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed pendingOwner);
    event GuardianChanged(address indexed guardian);
    event EmergencyPause(bool newLoansPaused, bool liquidationsPaused, address indexed by);
    event OperationScheduled(bytes32 indexed id, uint64 eta, bytes32 rationale, bytes[] calls);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id);
    event DelayChanged(uint256 delay);
    event BootstrapFinished();
    /// @dev Fired by every parameter setter. `key` identifies which setting moved, `subject` is the tier,
    ///      token or address concerned (zero for whole-struct settings), and `value` holds the new value
    ///      ABI-encoded.
    event ParamChanged(bytes32 indexed key, bytes32 indexed subject, bytes value);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotPendingOwner();
    error NoPendingOwner();
    error NotGuardian();
    /// @dev Only the owner may clear a halt; the guardian attempted to.
    error GuardianCannotUnpause();
    error NotSelf();
    error AlreadyBootstrapped();
    error DelayTooShort();
    /// @dev Queuing a batch with zero calls is pointless and is rejected.
    error EmptyBatch();
    error OperationExists();
    error OperationNotFound();
    error OperationNotReady();
    /// @dev The grace window for the batch has closed without it being run. Queue it again with a new salt.
    error OperationStale();
    /// @dev This batch has already been cancelled.
    error OperationAlreadyCancelled();
    error CallFailed(uint256 index, bytes reason);
    error InvalidBps();
    error InvalidTier();
    error InvalidParams();
    /// @dev An address parameter was set to zero, which is never a meaningful value for it.
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev After bootstrap the only accepted caller is this contract, reached through `execute`. Before that the
    ///      owner can call directly, and calls from the contract itself are also allowed so that batches can be
    ///      rehearsed through the timelock while bootstrap is still open.
    modifier onlyTimelocked() {
        if (bootstrapped) {
            if (msg.sender != address(this)) revert NotSelf();
        } else if (msg.sender != owner && msg.sender != address(this)) {
            revert NotOwner();
        }
        _;
    }

    /// @param delay_ Starting timelock delay. Any value is accepted here; the one-hour floor only starts to
    ///        apply once bootstrap has finished.
    constructor(address owner_, address guardian_, uint256 delay_) {
        owner = owner_;
        guardian = guardian_;
        delay = delay_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
        emit DelayChanged(delay_);
    }

    /*//////////////////////////////////////////////////////////////
                               OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice Offer ownership to `to`. The owner does not change until `to` accepts. To retract an offer, call
    ///         `cancelOwnershipTransfer` instead of offering to the zero address.
    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    /// @notice Retract an ownership offer before it is accepted.
    function cancelOwnershipTransfer() external onlyOwner {
        address offeredTo = pendingOwner;
        if (offeredTo == address(0)) revert NoPendingOwner();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(offeredTo);
    }

    /// @notice Take up an ownership offer made through `transferOwnership`.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                            GUARDIAN HALTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the halt flags for new loans and for liquidations. The guardian, the owner and the timelock
    ///         may all call it. Each call writes both flags, so clearing one means passing the current value of
    ///         the other. Repayments are never affected by either flag.
    /// @dev The guardian can switch a flag on but never off. Its key is designed to be easy to reach in a hurry,
    ///      which also makes it the key most likely to be compromised, and it skips the timelock only because a
    ///      halt can do no worse than lose the protocol some business. Allowing it to clear flags would let that
    ///      same key reverse a halt the owner imposed on purpose, inverting the trade-off. Reopening is never as
    ///      urgent as closing, so it is left to the owner.
    function setPaused(bool newLoans, bool liquidations) external {
        bool privileged = msg.sender == owner || msg.sender == address(this);
        if (!privileged && msg.sender != guardian) revert NotGuardian();
        if (!privileged && _clearsAFlag(newLoans, liquidations)) revert GuardianCannotUnpause();
        newLoansPaused = newLoans;
        liquidationsPaused = liquidations;
        emit EmergencyPause(newLoans, liquidations, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          TIMELOCK OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue a batch of setter calls. It becomes runnable after `delay` and stays runnable for
    ///         `GRACE_PERIOD` beyond that. `rationale` should be the hash of a public write-up of the change.
    /// @dev A batch id can be queued only once in its lifetime, even if it was later run, cancelled or allowed
    ///      to lapse; to queue identical calls again, use another salt. Batches with no calls are rejected.
    function schedule(bytes[] calldata calls, bytes32 salt, bytes32 rationale) external onlyOwner returns (bytes32 id) {
        if (calls.length == 0) revert EmptyBatch();
        id = operationId(calls, salt);
        if (operations[id].eta != 0) revert OperationExists();
        uint64 eta = uint64(block.timestamp + delay);
        operations[id] = Operation({eta: eta, executed: false, cancelled: false, rationale: rationale});
        emit OperationScheduled(id, eta, rationale, calls);
    }

    /// @notice Run a queued batch after its eta and before its grace window closes. Each call is made on this
    ///         contract in sequence, and if any one fails the whole batch is rolled back. A batch can run once.
    /// @dev The point of the delay is to give anyone affected by a change time to see it coming and respond. If a
    ///      batch could sit runnable forever, the delay would work the other way: it would become an option the
    ///      owner could exercise whenever it suited them, well after people had read it and possibly after the
    ///      protocol had changed around it. So once the grace window passes the batch expires and must be queued
    ///      afresh, giving everyone another chance to read it.
    function execute(bytes[] calldata calls, bytes32 salt) external onlyOwner {
        bytes32 id = operationId(calls, salt);
        Operation storage op = operations[id];
        if (op.eta == 0 || op.cancelled || op.executed) revert OperationNotFound();
        if (block.timestamp < op.eta) revert OperationNotReady();
        if (block.timestamp > op.eta + GRACE_PERIOD) revert OperationStale();
        op.executed = true;
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(this).call(calls[i]);
            if (!ok) revert CallFailed(i, reason);
        }
        emit OperationExecuted(id);
    }

    /// @notice Drop a queued batch. Batches that have already run cannot be dropped, and a second cancellation
    ///         of the same batch reverts, so `OperationCancelled` is only emitted for an actual change.
    function cancel(bytes32 id) external onlyOwner {
        Operation storage op = operations[id];
        if (op.eta == 0 || op.executed) revert OperationNotFound();
        if (op.cancelled) revert OperationAlreadyCancelled();
        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /// @notice Close the bootstrap phase, irreversibly. Afterwards every setter has to go through a queued and
    ///         executed batch, and the delay has a floor of one hour.
    function finishBootstrap() external onlyOwner {
        if (bootstrapped) revert AlreadyBootstrapped();
        bootstrapped = true;
        emit BootstrapFinished();
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Appoint a new guardian. Subject to the timelock in the same way as every other setting.
    function setGuardian(address guardian_) external onlyTimelocked {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    /// @notice Update the timelock delay. Once bootstrap has ended the minimum is one hour; before that, any
    ///         value including zero is allowed.
    function setDelay(uint256 delay_) external onlyTimelocked {
        if (bootstrapped && delay_ < 1 hours) revert DelayTooShort();
        delay = delay_;
        emit DelayChanged(delay_);
    }

    /// @notice Define an LTV tier. The opening ceiling may not exceed the liquidation threshold, which may not
    ///         exceed 100 percent, and the closed-market haircut may not exceed the opening ceiling, so no
    ///         haircut can drive a ceiling negative. Tier 0 is reserved to mean "unassigned" and is rejected.
    function setTierConfig(uint8 tier, TierConfig calldata cfg) external onlyTimelocked {
        if (tier == 0) revert InvalidTier();
        if (cfg.maxLtvBps > cfg.liqLtvBps || cfg.liqLtvBps > LoanTypes.BPS || cfg.closedHaircutBps > cfg.maxLtvBps) {
            revert InvalidBps();
        }
        _tiers[tier] = cfg;
        emit ParamChanged("tier", bytes32(uint256(tier)), abi.encode(cfg));
    }

    /// @notice Place a collateral token in a tier and give it an exposure cap. Enabling a token requires its
    ///         tier to be enabled at that moment. The check is not repeated later, so switching a tier off
    ///         afterwards leaves its existing tokens enabled.
    function setTokenConfig(address token, TokenConfig calldata cfg) external onlyTimelocked {
        if (cfg.enabled && !_tiers[cfg.tier].enabled) revert InvalidTier();
        _tokens[token] = cfg;
        emit ParamChanged("token", _addressKey(token), abi.encode(cfg));
    }

    /// @notice Turn a token on or off as a currency loans can be written in.
    function setLoanTokenEnabled(address token, bool enabled) external onlyTimelocked {
        if (token == address(0)) revert ZeroAddress();
        loanTokenEnabled[token] = enabled;
        emit ParamChanged("loanToken", _addressKey(token), abi.encode(enabled));
    }

    /// @notice Turn a loan duration, given in seconds, on or off.
    function setTermAllowed(uint32 termSeconds, bool allowed) external onlyTimelocked {
        termAllowed[termSeconds] = allowed;
        emit ParamChanged("term", bytes32(uint256(termSeconds)), abi.encode(allowed));
    }

    /// @notice Replace the general loan parameters.
    /// @dev `maxSlicesPerLoan` cannot be zero, since every origination would then fail on its very first
    ///      slice, and no sensible proposal would ask for that.
    function setLoanParams(LoanParams calldata p) external onlyTimelocked {
        if (p.maxSlicesPerLoan == 0) revert InvalidParams();
        _loanParams = p;
        emit ParamChanged("loanParams", bytes32(0), abi.encode(p));
    }

    /// @notice Replace the liquidation auction parameters.
    /// @dev Floors and shares are each capped at 100 percent individually. The start premium has no cap: the
    ///      auction starts at the guard price plus the premium and its floor is a fraction of the guard price,
    ///      so start and floor can never swap places. A zero duration is rejected, as it would start every
    ///      auction at the floor.
    function setAuctionParams(AuctionParams calldata p) external onlyTimelocked {
        if (
            p.floorBpsRegular > LoanTypes.BPS || p.floorBpsClosed > LoanTypes.BPS || p.penaltyBps > LoanTypes.BPS
                || p.keeperShareBps > LoanTypes.BPS || p.lenderPenaltyShareBps > LoanTypes.BPS
        ) revert InvalidBps();
        if (p.duration == 0) revert InvalidParams();
        _auctionParams = p;
        emit ParamChanged("auctionParams", bytes32(0), abi.encode(p));
    }

    /// @notice Replace the rollover market's auction parameters.
    /// @dev A zero duration is rejected because the rate would hit its ceiling immediately, leaving only an
    ///      acceptance in the very first block able to clear, which defeats the purpose of an auction. The cap
    ///      spread has no upper bound here.
    function setRefinanceParams(RefinanceParams calldata p) external onlyTimelocked {
        if (p.duration == 0) revert InvalidParams();
        _refinanceParams = p;
        emit ParamChanged("refinanceParams", bytes32(0), abi.encode(p));
    }

    /// @notice Replace the fee schedule. Every rate is capped at 100 percent on its own.
    function setFeeParams(FeeParams calldata p) external onlyTimelocked {
        if (
            p.originationBps > LoanTypes.BPS || p.interestShareBps > LoanTypes.BPS || p.refinanceBps > LoanTypes.BPS
                || p.idleYieldShareBps > LoanTypes.BPS
        ) revert InvalidBps();
        _feeParams = p;
        emit ParamChanged("feeParams", bytes32(0), abi.encode(p));
    }

    /// @notice Add or remove an ERC-4626 vault from the list allowed to hold idle lender funds. The reserve
    ///         adapter consults this list a single time, at deployment.
    function setVaultWhitelisted(address vault, bool ok) external onlyTimelocked {
        if (vault == address(0)) revert ZeroAddress();
        vaultWhitelisted[vault] = ok;
        emit ParamChanged("vault", _addressKey(vault), abi.encode(ok));
    }

    /// @notice Add or remove a credential issuer. Removing an issuer voids all credentials it has issued.
    function setAttestationIssuer(address issuer, bool ok) external onlyTimelocked {
        if (issuer == address(0)) revert ZeroAddress();
        attestationIssuer[issuer] = ok;
        emit ParamChanged("attestationIssuer", _addressKey(issuer), abi.encode(ok));
    }

    /// @notice Choose the adapter the permission registry defers to. The change applies from the next
    ///         eligibility lookup.
    /// @dev Zero is rejected because the permission registry reverts on every lookup when it has no adapter,
    ///      which would stop originations, rollovers and slice note transfers all together.
    function setEligibilityAdapter(address adapter) external onlyTimelocked {
        if (adapter == address(0)) revert ZeroAddress();
        eligibilityAdapter = adapter;
        emit ParamChanged("eligibilityAdapter", _addressKey(adapter), "");
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Id of a batch, computed by hashing its list of calls together with the salt. Changing the salt
    ///         lets the same calls be queued again.
    function operationId(bytes[] calldata calls, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(calls, salt));
    }

    /// @notice Where batch `id` currently stands: unknown, waiting for its delay, ready, expired, executed or
    ///         cancelled. Mirrors the checks in `execute` so callers need not reimplement them.
    function operationState(bytes32 id) external view returns (OperationState) {
        Operation storage op = operations[id];
        if (op.eta == 0) return OperationState.Unknown;
        if (op.executed) return OperationState.Executed;
        if (op.cancelled) return OperationState.Cancelled;
        if (block.timestamp < op.eta) return OperationState.Waiting;
        if (block.timestamp > op.eta + GRACE_PERIOD) return OperationState.Stale;
        return OperationState.Ready;
    }

    function tierConfig(uint8 tier) external view override returns (TierConfig memory) {
        return _tiers[tier];
    }

    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokens[token];
    }

    function loanParams() external view override returns (LoanParams memory) {
        return _loanParams;
    }

    function auctionParams() external view override returns (AuctionParams memory) {
        return _auctionParams;
    }

    function refinanceParams() external view override returns (RefinanceParams memory) {
        return _refinanceParams;
    }

    function feeParams() external view override returns (FeeParams memory) {
        return _feeParams;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev True if applying the requested flags would switch off a halt that is currently on.
    function _clearsAFlag(bool newLoans, bool liquidations) internal view returns (bool) {
        return (newLoansPaused && !newLoans) || (liquidationsPaused && !liquidations);
    }

    /// @dev Left-pads an address into the `subject` slot of `ParamChanged`.
    function _addressKey(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
