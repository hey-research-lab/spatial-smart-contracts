// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessAdapter} from "../interfaces/IPermissionRegistry.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";

/// @title CredentialRegistry
/// @notice A lightweight, EAS-style credential store maintained by Spatial for networks where EAS itself is not
///         available. Each entry ties an (account, role) pair to a jurisdiction code, an investor class and an
///         expiry time; no personal data is kept on chain. Only issuers that the risk config has approved can
///         write, which in practice means KYC vendors and the signing services they operate.
contract CredentialRegistry is IAccessAdapter {
    struct Attestation {
        bytes32 uid;
        address issuer;
        /// @dev Free-form two-byte code picked by the issuer. Kept for off-chain indexing; the contract never
        ///      reads it.
        bytes2 jurisdictionClass;
        /// @dev Numeric class picked by the issuer. Stored for reference only.
        uint8 investorClass;
        uint64 issuedAt;
        uint64 expiry;
        bool revoked;
    }

    IRiskConfig public immutable riskConfig;
    /// @notice Running counter mixed into each uid, guaranteeing uniqueness across all entries.
    uint256 public nonce;

    mapping(address => mapping(bytes32 => Attestation)) internal _credentials;

    event Attested(
        address indexed account,
        bytes32 indexed role,
        bytes32 uid,
        address indexed issuer,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    );
    event Revoked(address indexed account, bytes32 indexed role, bytes32 uid, address indexed issuer);

    error NotIssuer();
    error BadExpiry();
    error NoActiveRecord();
    error ZeroAccount();
    error LengthMismatch();

    /// @dev Approval is checked against the risk config each time rather than cached, so an issuer that loses
    ///      approval cannot write from that block onwards.
    modifier onlyIssuer() {
        if (!riskConfig.attestationIssuer(msg.sender)) revert NotIssuer();
        _;
    }

    constructor(IRiskConfig riskConfig_) {
        riskConfig = riskConfig_;
    }

    /*//////////////////////////////////////////////////////////////
                                 ISSUING
    //////////////////////////////////////////////////////////////*/

    /// @notice Write a credential granting `role` to `account`. If the pair already has an entry, revoked or
    ///         not, it is replaced in full.
    /// @param account Address receiving the credential; the zero address is rejected.
    /// @param expiry Timestamp at which the credential lapses; it has to be later than the current block.
    /// @return uid Fresh identifier for the entry, hashed from the account, role, issuer, nonce and chain id.
    function attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        external
        onlyIssuer
        returns (bytes32 uid)
    {
        return _store(account, role, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Bulk version of `attest`: one role and one expiry applied to a list of accounts, for example a
    ///         cohort the issuer has finished screening. Every account still receives a separate entry and its
    ///         own `Attested` event.
    /// @dev `accounts`, `jurisdictionClasses` and `investorClasses` are paired by index and their lengths must
    ///      agree. A single invalid entry rolls back the entire call.
    /// @return uids Identifiers of the new entries, matching the order of `accounts`.
    function attestMany(
        address[] calldata accounts,
        bytes32 role,
        bytes2[] calldata jurisdictionClasses,
        uint8[] calldata investorClasses,
        uint64 expiry
    ) external onlyIssuer returns (bytes32[] memory uids) {
        uint256 count = accounts.length;
        if (jurisdictionClasses.length != count || investorClasses.length != count) revert LengthMismatch();
        uids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            uids[i] = _store(accounts[i], role, jurisdictionClasses[i], investorClasses[i], expiry);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REVOCATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancel the credential for `account` in `role`, effective straight away. Revocation is not limited
    ///         to the original issuer: any approved issuer may do it, which lets a healthy issuer clear up after
    ///         one whose keys were compromised.
    /// @dev Fails with `NoActiveRecord` if there is nothing to cancel or the entry was already cancelled, which
    ///      guarantees each `Revoked` event reflects a genuine state change with a non-zero uid.
    function revoke(address account, bytes32 role) external onlyIssuer {
        _cancel(account, role);
    }

    /// @notice Bulk version of `revoke` for a list of accounts sharing one role, useful when a whole cohort
    ///         has to be withdrawn. The same rules apply to each account, so a single account without a live
    ///         entry causes the entire call to revert.
    function revokeMany(address[] calldata accounts, bytes32 role) external onlyIssuer {
        uint256 count = accounts.length;
        for (uint256 i; i < count; ++i) {
            _cancel(accounts[i], role);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true only if an entry is present, has not been cancelled, has not lapsed, and its issuer
    ///         is still approved by the risk config. Withdrawing an issuer's approval thus switches off every
    ///         credential it wrote in one step.
    function isEligible(address account, bytes32 role) external view override returns (bool) {
        Attestation storage entry = _credentials[account][role];
        return entry.uid != bytes32(0) && !entry.revoked && entry.expiry > block.timestamp
            && riskConfig.attestationIssuer(entry.issuer);
    }

    /// @notice Raw uid and expiry stored for the pair, both zero when nothing was written. Revocation and
    ///         issuer approval are not taken into account here; call `isEligible` for the actual answer.
    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        Attestation storage entry = _credentials[account][role];
        return (entry.uid, entry.expiry);
    }

    /// @notice Full stored entry for the pair, intended for indexers and block explorers.
    function attestation(address account, bytes32 role) external view returns (Attestation memory) {
        return _credentials[account][role];
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates the inputs, derives the uid, overwrites the slot and emits `Attested`.
    function _store(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        internal
        returns (bytes32 uid)
    {
        if (account == address(0)) revert ZeroAccount();
        if (expiry <= block.timestamp) revert BadExpiry();
        uid = keccak256(abi.encodePacked(account, role, msg.sender, ++nonce, block.chainid));
        _credentials[account][role] = Attestation({
            uid: uid,
            issuer: msg.sender,
            jurisdictionClass: jurisdictionClass,
            investorClass: investorClass,
            issuedAt: uint64(block.timestamp),
            expiry: expiry,
            revoked: false
        });
        emit Attested(account, role, uid, msg.sender, jurisdictionClass, investorClass, expiry);
    }

    /// @dev Flags a live entry as revoked and emits `Revoked`, reverting if there is no live entry.
    function _cancel(address account, bytes32 role) internal {
        Attestation storage entry = _credentials[account][role];
        if (entry.uid == bytes32(0) || entry.revoked) revert NoActiveRecord();
        entry.revoked = true;
        emit Revoked(account, role, entry.uid, msg.sender);
    }
}
