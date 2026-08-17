// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoanTypes} from "./LoanTypes.sol";

/// @title QuoteHash
/// @notice Typed-data hashing for the two signed messages, `LendOffer` and `BorrowRequest`, plus the key that
///         restricts a lend offer to the rollover of a single loan.
/// @dev Each type string lists its fields in the same order as the matching struct in `LoanTypes`, and `Side`
///      is hashed as a `uint8`. Signers combine these struct hashes with the quote book's domain, named
///      `Spatial` at version `1`.
library QuoteHash {
    /*//////////////////////////////////////////////////////////////
                              TYPE HASHES
    //////////////////////////////////////////////////////////////*/

    /// @dev Hash of the EIP-712 type string describing a lend offer.
    bytes32 internal constant LEND_OFFER_TYPEHASH = keccak256(
        "LendOffer(address maker,uint8 side,address collateralToken,address loanToken,uint256 principalMin,"
        "uint256 principalMax,uint16 aprBps,uint16 maxLtvBps,uint32 termSeconds,uint40 expiry,uint256 nonce,"
        "bytes32 salt,bytes32 requestId,uint8 flags)"
    );

    /// @dev Hash of the EIP-712 type string describing a borrow request.
    bytes32 internal constant BORROW_REQUEST_TYPEHASH = keccak256(
        "BorrowRequest(address borrower,address collateralToken,address loanToken,uint256 collateralAmount,"
        "uint256 principal,uint16 maxAprBps,uint32 termSeconds,uint40 fillDeadline,bytes32 salt)"
    );

    /*//////////////////////////////////////////////////////////////
                            STRUCT HASHING
    //////////////////////////////////////////////////////////////*/

    /// @notice Typed-data struct hash for a lend offer, before any domain is applied. The quote book combines it
    ///         with the domain separator to produce the digest the lender signs.
    /// @param offer Offer to hash.
    /// @return The EIP-712 `hashStruct` of `offer`.
    function hashOffer(LoanTypes.LendOffer calldata offer) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LEND_OFFER_TYPEHASH,
                offer.maker,
                uint8(offer.side),
                offer.collateralToken,
                offer.loanToken,
                offer.principalMin,
                offer.principalMax,
                offer.aprBps,
                offer.maxLtvBps,
                offer.termSeconds,
                offer.expiry,
                offer.nonce,
                offer.salt,
                offer.requestId,
                offer.flags
            )
        );
    }

    /// @notice Typed-data struct hash for a borrow request, before any domain is applied.
    /// @param request Request to hash.
    /// @return The EIP-712 `hashStruct` of `request`.
    function hashRequest(LoanTypes.BorrowRequest calldata request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BORROW_REQUEST_TYPEHASH,
                request.borrower,
                request.collateralToken,
                request.loanToken,
                request.collateralAmount,
                request.principal,
                request.maxAprBps,
                request.termSeconds,
                request.fillDeadline,
                request.salt
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                             ROLLOVER KEY
    //////////////////////////////////////////////////////////////*/

    /// @notice Value to place in an offer's `requestId` so that it can only be used to roll over `loanId`.
    /// @dev Hashing a fixed text prefix with the id means the key can never coincide with a borrow request
    ///      digest. Rollovers also take offers whose `requestId` is zero; setting this key simply confines an
    ///      offer to one particular loan.
    /// @param loanId Loan whose rollover the offer is meant for.
    /// @return Key binding an offer to the rollover of `loanId`.
    function rolloverKey(uint256 loanId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("spatial.rollover", loanId));
    }
}
