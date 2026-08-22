// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ISliceNote} from "./interfaces/ISliceNote.sol";
import {ICreditHub} from "./interfaces/ICreditHub.sol";
import {IPermissionRegistry} from "./interfaces/IPermissionRegistry.sol";
import {IRiskConfig} from "./interfaces/IRiskConfig.sol";

/// @title SliceNote
/// @notice ERC-721 collection "Spatial Slice Note" (SPSN). Each lender's share of a loan is represented by one
///         slice note whose token id equals the slice id. Only the hub can create or destroy tokens, and a
///         slice note can change hands only if the receiving address passes the permission registry's lender
///         check.
contract SliceNote is ERC721, ISliceNote {
    using Strings for uint256;

    IPermissionRegistry public immutable permissions;
    IRiskConfig public immutable riskConfig;
    /// @notice Address of the hub, fixed once by governance. It is the only account able to mint or burn.
    address public hub;
    string public baseURI;

    event DeskSet(address hub);
    event BaseURISet(string baseURI);
    /// @notice ERC-4906 signal that metadata for ids `_fromTokenId` through `_toTokenId` should be refreshed.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @dev Interface id that ERC-4906 assigns to itself for ERC-165 detection.
    bytes4 private constant _ERC4906_ID = 0x49064906;

    error NotHub();
    error NotGovernance();
    error HubAlreadySet();
    error ZeroHub();

    constructor(IPermissionRegistry permissions_, IRiskConfig riskConfig_) ERC721("Spatial Slice Note", "SPSN") {
        permissions = permissions_;
        riskConfig = riskConfig_;
    }

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time wiring of the hub address, performed by the risk config owner after deployment. A second
    ///         call fails, and so does an attempt to set the zero address.
    function setDesk(address hub_) external {
        _onlyGovernance();
        if (hub != address(0)) revert HubAlreadySet();
        if (hub_ == address(0)) revert ZeroHub();
        hub = hub_;
        emit DeskSet(hub_);
    }

    /// @notice Update the prefix used to build token URIs. The risk config owner may call this whenever needed.
    /// @dev Alongside `BaseURISet`, fires an ERC-4906 `BatchMetadataUpdate` spanning the full id range so that
    ///      wallets and marketplaces holding cached metadata reload it.
    function setBaseURI(string calldata uri) external {
        _onlyGovernance();
        baseURI = uri;
        emit BaseURISet(uri);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              HUB ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISliceNote
    function mint(address to, uint256 sliceId) external override onlyHub {
        _mint(to, sliceId);
    }

    /// @inheritdoc ISliceNote
    function burn(uint256 sliceId) external override onlyHub {
        _burn(sliceId);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true while the slice note for `sliceId` is live, meaning it was minted and has not been
    ///         burned since. Cheaper than calling `ownerOf`, which reverts for unknown ids.
    function exists(uint256 sliceId) external view returns (bool) {
        return _ownerOf(sliceId) != address(0);
    }

    /// @dev Reports ERC-4906 support in addition to everything ERC721 already declares, and settles the double
    ///      inheritance of IERC165 that comes in through ISliceNote.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == _ERC4906_ID || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts with `NotGovernance` unless the caller owns the risk config.
    function _onlyGovernance() private view {
        if (msg.sender != riskConfig.owner()) revert NotGovernance();
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /// @dev Minting and burning are not gated here. For a transfer between two real holders, the recipient must
    ///      clear the permission registry's lender check and the hub is told about the new owner, so future
    ///      interest and principal are paid to them. Both steps run before the ownership update, so any failure
    ///      unwinds cleanly.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        bool holderToHolder = from != address(0) && to != address(0);
        if (holderToHolder) {
            permissions.requireLender(to);
            ICreditHub(hub).onSliceTransfer(tokenId, to);
        }
        return super._update(to, tokenId, auth);
    }
}
