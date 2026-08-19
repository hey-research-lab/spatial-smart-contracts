// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ISliceNote
/// @notice Token interface for slice notes, the ERC-721 representing each lender's share of a loan. Token ids are
///         the slice ids themselves.
interface ISliceNote is IERC721 {
    /// @notice Create the slice note for a freshly opened slice and assign it to the lender. Callable by the hub
    ///         alone.
    function mint(address to, uint256 sliceId) external;
    /// @notice Destroy the slice note after its slice has been fully settled. Callable by the hub alone.
    function burn(uint256 sliceId) external;
}
