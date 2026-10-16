// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IReserveAdapter} from "./interfaces/IReserveAdapter.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";

/// @title ReserveAdapter
/// @notice Puts idle lender USDG to work in one approved ERC-4626 vault (on Robinhood Chain, the Morpho vault)
///         and releases it to the hub as soon as a loan is funded. The reserve adapter is the sole depositor seen
///         by the vault and tracks, in `shares`, how much of that position belongs to each lender. Funds can only
///         ever move into the vault, back to the lender who owns them, or to a destination chosen by the hub.
/// @dev Vault approval is re-checked on each deposit instead of only at construction. That way, when the risk
///      config drops a vault from its whitelist, fresh deposits stop while all withdrawal routes keep working,
///      letting governance wind a vault down without locking up lender funds already inside it.
contract ReserveAdapter is IReserveAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRiskConfig public immutable riskConfig;
    /// @dev Named with a trailing underscore so they do not collide with the `vault()` and `asset()` functions
    ///      demanded by IReserveAdapter.
    IERC4626 public immutable vault_;
    IERC20 public immutable asset_;
    /// @notice Address of the hub, the only account permitted to call `withdrawFor` and `depositFor`.
    address public hub;

    /// @notice Per-lender vault share balances. Together they add up to the vault shares this contract owns.
    mapping(address => uint256) public shares;

    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, address indexed to, uint256 assets, uint256 shares);
    event DeskSet(address hub);
    /// @notice Emitted when funds headed for the vault on a repayment were paid straight to the lender, because
    ///         the risk config has removed the vault from its whitelist.
    event ParkingSkipped(address indexed lender, uint256 assets);

    error NotHub();
    error NotGovernance();
    error VaultNotWhitelisted();
    error InsufficientReserve();
    error HubAlreadySet();
    error ZeroHub();
    error ZeroAmount();
    error ZeroRecipient();

    /// @dev Construction fails unless the risk config already whitelists the vault (deposits check this again
    ///      later). The vault receives a maximum allowance over the asset here and never needs another.
    constructor(IRiskConfig riskConfig_, IERC4626 vault__) {
        if (!riskConfig_.vaultWhitelisted(address(vault__))) revert VaultNotWhitelisted();
        riskConfig = riskConfig_;
        vault_ = vault__;
        asset_ = IERC20(vault__.asset());
        asset_.forceApprove(address(vault__), type(uint256).max);
    }

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time wiring of the hub address by the risk config owner. Calling it again fails, as does
    ///         supplying the zero address.
    function setDesk(address hub_) external {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
        if (hub != address(0)) revert HubAlreadySet();
        if (hub_ == address(0)) revert ZeroHub();
        hub = hub_;
        emit DeskSet(hub_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IReserveAdapter
    function vault() external view override returns (address) {
        return address(vault_);
    }

    /// @inheritdoc IReserveAdapter
    function asset() external view override returns (address) {
        return address(asset_);
    }

    /// @notice Value of a lender's shares expressed in the underlying asset, using the vault's own conversion,
    ///         which rounds down.
    function balanceOf(address lender) external view override returns (uint256) {
        return vault_.convertToAssets(shares[lender]);
    }

    /// @notice Value of every share this adapter holds in the vault, which is the sum of all lender positions
    ///         give or take rounding.
    function totalAssets() external view returns (uint256) {
        return vault_.convertToAssets(vault_.balanceOf(address(this)));
    }

    /// @notice Largest amount `lender` can take out right now with `withdraw`. This is the smaller of their
    ///         position and what the vault itself is willing to release, so it can be lower than `balanceOf`
    ///         when the vault is short on liquidity.
    function maxWithdraw(address lender) external view returns (uint256) {
        uint256 owned = vault_.convertToAssets(shares[lender]);
        uint256 available = vault_.maxWithdraw(address(this));
        return owned < available ? owned : available;
    }

    /*//////////////////////////////////////////////////////////////
                             LENDER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull `assets` from the caller (an allowance must already be in place) and put them in the vault
    ///         on the caller's behalf.
    /// @dev Rejected while the vault is off the risk config whitelist. Withdrawals remain available throughout,
    ///      so retiring a vault blocks new money without trapping existing balances.
    function deposit(uint256 assets) external override nonReentrant {
        if (assets == 0) revert ZeroAmount();
        if (!riskConfig.vaultWhitelisted(address(vault_))) revert VaultNotWhitelisted();
        asset_.safeTransferFrom(msg.sender, address(this), assets);
        _creditShares(msg.sender, assets);
    }

    /// @notice Take `assets` out of the caller's position and deliver them to `to`.
    /// @dev A zero amount or zero recipient is rejected on this lender route only. The hub routes do not repeat
    ///      these checks because the hub works out amounts and destinations itself.
    function withdraw(uint256 assets, address to) external override nonReentrant {
        if (assets == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroRecipient();
        _debitShares(msg.sender, assets, to);
    }

    /// @dev Because `balanceOf` rounds down, withdrawing exactly that amount may strand a dust share. Redeeming
    ///      every share the caller holds avoids this and leaves the position at exactly zero.
    function withdrawAll(address to) external override nonReentrant returns (uint256 assets) {
        if (to == address(0)) revert ZeroRecipient();
        uint256 owned = shares[msg.sender];
        if (owned == 0) revert InsufficientReserve();
        shares[msg.sender] = 0;
        assets = vault_.redeem(owned, to, address(this));
        emit Withdrawn(msg.sender, to, assets, owned);
    }

    /*//////////////////////////////////////////////////////////////
                              HUB ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricted to the hub. Used to pull a lender's principal at the moment a loan originates, and to
    ///         process withdrawals that a lender requests through the hub.
    function withdrawFor(address lender, uint256 assets, address to) external override onlyHub nonReentrant {
        _debitShares(lender, assets, to);
    }

    /// @notice Restricted to the hub. Receives `assets` from the hub and books the vault shares they buy to
    ///         `lender`; this is the route by which repaid capital flows back to a lender who keeps idle funds
    ///         here.
    /// @dev Unlike `deposit`, this must not fail when the vault has been de-whitelisted, since it is called from
    ///      repayment and liquidation and no governance setting may halt those flows. In that case the funds
    ///      are forwarded to the lender's wallet and the lender decides where to put them next.
    function depositFor(address lender, uint256 assets) external override onlyHub nonReentrant {
        asset_.safeTransferFrom(msg.sender, address(this), assets);
        if (!riskConfig.vaultWhitelisted(address(vault_))) {
            asset_.safeTransfer(lender, assets);
            emit ParkingSkipped(lender, assets);
            return;
        }
        _creditShares(lender, assets);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Supplies `assets` to the vault and adds the shares received to `lender`'s balance.
    function _creditShares(address lender, uint256 assets) internal {
        uint256 received = vault_.deposit(assets, address(this));
        shares[lender] += received;
        emit Deposited(lender, assets, received);
    }

    /// @dev Checks the lender has enough before touching the vault, treating `previewWithdraw` as a ceiling on
    ///      the shares that will be burned. ERC-4626 forbids burning more than the preview, so subtracting the
    ///      real burn from the lender's balance is always safe.
    function _debitShares(address lender, uint256 assets, address to) internal {
        if (vault_.previewWithdraw(assets) > shares[lender]) revert InsufficientReserve();
        uint256 spent = vault_.withdraw(assets, to, address(this));
        shares[lender] -= spent;
        emit Withdrawn(lender, to, assets, spent);
    }
}
