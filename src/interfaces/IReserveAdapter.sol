// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IReserveAdapter
/// @notice Earns yield on lender capital that is waiting to be matched by holding it in an approved ERC-4626
///         vault, and gives the hub immediate access to it when an offer is filled.
interface IReserveAdapter {
    /// @notice Underlying token of the vault; this is the same loan token lenders deposit.
    function asset() external view returns (address);
    /// @notice Address of the ERC-4626 vault where idle capital is held.
    function vault() external view returns (address);
    /// @notice Current value of a lender's position, denominated in the underlying asset.
    function balanceOf(address lender) external view returns (uint256 assets);
    /// @notice Move `assets` from the caller into the vault on their behalf.
    function deposit(uint256 assets) external;
    /// @notice Take `assets` out of the caller's position and deliver them to `to`.
    function withdraw(uint256 assets, address to) external;
    /// @dev Burns all of the caller's shares in one go so that no dust is left over.
    function withdrawAll(address to) external returns (uint256 assets);
    /// @dev Restricted to the hub. Removes `assets` from `lender`'s position and pays them to `to`.
    function withdrawFor(address lender, uint256 assets, address to) external;
    /// @dev Restricted to the hub. Collects `assets` from the caller and credits the resulting position to
    ///      `lender`.
    function depositFor(address lender, uint256 assets) external;
}
