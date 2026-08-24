// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LoanTypes} from "./libraries/LoanTypes.sol";
import {QuoteHash} from "./libraries/QuoteHash.sol";

/// @title QuoteBook
/// @notice Base contract of the hub that keeps track of signed lend offers. It owns the EIP-712 domain, holds a
///         cancellation bitmap for each maker, and remembers how much principal each offer digest has supplied.
/// @dev Nonces here are cancellation handles rather than sequence numbers. A fill does not spend the nonce, and a
///      maker can reuse one nonce across many offers in order to kill them all together. Usage is tallied per
///      digest, so a standing offer keeps funding loans until its `principalMax` is reached. Signature checks use
///      OpenZeppelin's SignatureChecker, which accepts both plain ECDSA keys and EIP-1271 contract wallets.
///
///      The domain carries the name `Spatial`, version `1`, the chain id and the hub's address. It is assembled
///      by hand here, without inheriting an EIP-712 helper contract, because the hub has little bytecode to spare.
abstract contract QuoteBook {
    using QuoteHash for LoanTypes.LendOffer;

    /// @dev Type hash for the standard four-field `EIP712Domain` struct.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev Hash of the domain's name string.
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("Spatial");
    /// @dev Hash of the domain's version string.
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("1");

    bytes32 private immutable _deployDomainSeparator;
    uint256 private immutable _deployChainId;

    /// @dev For each maker, a 256-bit word per `nonce >> 8`; a bit that is set marks that nonce as cancelled.
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;
    /// @dev Running total of principal drawn against each offer digest.
    mapping(bytes32 => uint256) public filled;

    /// @notice `maker` cancelled a single `nonce`.
    event OfferCancelled(address indexed maker, uint256 nonce);
    /// @notice `maker` cancelled, within word `wordPos`, every nonce whose bit is set in `mask`.
    event OfferWordCancelled(address indexed maker, uint256 wordPos, uint256 mask);
    /// @notice An offer supplied `fill` of principal, bringing its usage to `totalFilled`.
    event OfferFilled(bytes32 indexed offerHash, address indexed maker, uint256 fill, uint256 totalFilled);
    /// @notice Capacity from a fill that did not end up funding a loan was handed back; `totalFilled` is the
    ///         usage left on the offer afterwards.
    event OfferReleased(bytes32 indexed offerHash, uint256 release, uint256 totalFilled);

    /// @dev The offer is past its `expiry`.
    error OfferExpired(bytes32 offerHash);
    /// @dev The maker has cancelled the nonce this offer uses.
    error OfferWasCancelled(bytes32 offerHash);
    /// @dev The signature is not valid for `maker` over this digest, whether checked as ECDSA or via EIP-1271.
    error BadOfferSignature(bytes32 offerHash);
    /// @dev Taking this fill would push the offer's usage above `principalMax`.
    error OfferCapacityExceeded(bytes32 offerHash);

    /// @dev Records the chain id at deployment and the separator that goes with it.
    constructor() {
        _deployChainId = block.chainid;
        _deployDomainSeparator = _computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                          NONCE CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancels `nonce` for the caller, which kills every offer signed with it.
    /// @dev Safe to repeat. A second call on the same nonce leaves the bitmap as it was and simply emits again.
    function cancel(uint256 nonce) external {
        nonceBitmap[msg.sender][nonce >> 8] |= 1 << (nonce & 0xff);
        emit OfferCancelled(msg.sender, nonce);
    }

    /// @notice Bulk cancellation within one bitmap word. Every bit set in `mask` cancels the corresponding nonce
    ///         in the range `wordPos * 256` through `wordPos * 256 + 255`.
    function cancelWord(uint256 wordPos, uint256 mask) external {
        nonceBitmap[msg.sender][wordPos] |= mask;
        emit OfferWordCancelled(msg.sender, wordPos, mask);
    }

    /// @notice True if `maker` has cancelled `nonce`.
    function isNonceCancelled(address maker, uint256 nonce) public view returns (bool) {
        return nonceBitmap[maker][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /*//////////////////////////////////////////////////////////////
                           TYPED-DATA DIGESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current EIP-712 domain separator.
    /// @dev Reuses the value computed at deployment as long as the chain id is unchanged. If the chain has
    ///      forked, it is rebuilt with the new id, so signatures meant for the other branch fail here.
    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _deployChainId ? _deployDomainSeparator : _computeDomainSeparator();
    }

    /// @notice Digest a lender signs for `offer`, combining the domain separator with `QuoteHash.hashOffer`.
    function offerHash(LoanTypes.LendOffer calldata offer) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), offer.hashOffer());
    }

    /// @notice Digest a borrower signs for `request`. A lend offer aimed at this one request stores the same
    ///         value as its `requestId`.
    function requestHash(LoanTypes.BorrowRequest calldata request) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), QuoteHash.hashRequest(request));
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
    }

    /*//////////////////////////////////////////////////////////////
                          OFFER USE AND CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @notice How much more principal `offer` can supply, being its `principalMax` minus usage so far.
    function remainingCapacity(LoanTypes.LendOffer calldata offer) public view returns (uint256) {
        return _remainingCapacity(offerHash(offer), offer.principalMax);
    }

    /// @dev Same as `remainingCapacity`, but for a digest already in hand. Computing an offer digest encodes
    ///      fourteen fields and hashes twice, and origination needs the digest and the capacity of every offer
    ///      it processes, so taking the digest as an argument avoids hashing the offer again.
    function _remainingCapacity(bytes32 digest, uint256 principalMax) internal view returns (uint256) {
        uint256 drawn = filled[digest];
        return drawn >= principalMax ? 0 : principalMax - drawn;
    }

    /// @dev Confirms an offer can be used and returns its digest. In order, it must not have expired (an offer
    ///      is still good during its `expiry` second), its nonce must not be cancelled, and the signature must
    ///      belong to `maker`. Each failure reports the digest. Capacity is not checked here; `_recordFill`
    ///      handles it once the size of the fill is decided.
    function _authenticateOffer(LoanTypes.LendOffer calldata offer, bytes calldata signature)
        internal
        view
        returns (bytes32 digest)
    {
        digest = offerHash(offer);
        if (offer.expiry < block.timestamp) revert OfferExpired(digest);
        if (isNonceCancelled(offer.maker, offer.nonce)) revert OfferWasCancelled(digest);
        if (!SignatureChecker.isValidSignatureNow(offer.maker, digest, signature)) revert BadOfferSignature(digest);
    }

    /// @dev Adds `fill` to the usage of `digest`, and reverts if that would carry it beyond `principalMax`.
    function _recordFill(bytes32 digest, LoanTypes.LendOffer calldata offer, uint256 fill) internal {
        uint256 total = filled[digest] + fill;
        if (total > offer.principalMax) revert OfferCapacityExceeded(digest);
        filled[digest] = total;
        emit OfferFilled(digest, offer.maker, fill, total);
    }

    /// @dev Takes `amount` off the usage recorded for `digest`. Origination never needs this, since it records a
    ///      fill and writes the loan in one transaction. Rollovers do: acceptances are recorded one at a time as
    ///      they come in, and the auction can still fail and refund all of them. Leaving that usage in place
    ///      would quietly use up a lender's standing offer on a loan that never happened.
    ///
    ///      The subtraction saturates at zero instead of reverting, because this sits on the refund path and a
    ///      small accounting difference must never stop a refund from going through.
    function _releaseFill(bytes32 digest, uint256 amount) internal {
        uint256 drawn = filled[digest];
        uint256 total = amount >= drawn ? 0 : drawn - amount;
        filled[digest] = total;
        emit OfferReleased(digest, drawn - total, total);
    }
}
