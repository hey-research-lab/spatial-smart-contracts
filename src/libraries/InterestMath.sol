// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LoanTypes} from "./LoanTypes.sol";

/// @title InterestMath
/// @notice Accrual rules for slices. Each slice earns a fixed annual rate, counted second by second on its
///         principal alone; interest never earns interest.
/// @dev Inputs are in base units of the loan token, with rates in basis points. All multiplications happen
///      before the one division, so the result is truncated a single time. Because principal fits in `uint128`,
///      the full product stays far below the `uint256` ceiling.
library InterestMath {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                              PURE MATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simple interest on `principal` at an annual rate of `aprBps` for a span of `elapsed` seconds.
    /// @dev Computes `principal * aprBps * elapsed` and divides once by `BPS * YEAR`, truncating.
    function linear(uint256 principal, uint256 aprBps, uint256 elapsed) internal pure returns (uint256) {
        return principal * aprBps * elapsed / (LoanTypes.BPS * LoanTypes.YEAR);
    }

    /*//////////////////////////////////////////////////////////////
                             SLICE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds interest earned between `lastAccrual` and `nowTs` to the slice and moves its accrual mark
    ///         forward to `nowTs`.
    /// @dev Does nothing if `nowTs` is at or before the current mark, which makes a second call in the same
    ///      block a no-op. The new interest is cast to `uint128` with an overflow check.
    function settleTo(LoanTypes.Slice storage slice, uint40 nowTs) internal {
        if (nowTs <= slice.lastAccrual) return;
        uint256 earned = linear(slice.principal, slice.aprBps, nowTs - slice.lastAccrual);
        slice.accruedInterest += earned.toUint128();
        slice.lastAccrual = nowTs;
    }

    /// @notice Unpaid interest on a slice, measured at its most recent accrual mark.
    /// @dev Takes whichever is higher of the booked interest and the minimum-interest floor, then subtracts what
    ///      has been paid, bottoming out at zero.
    function owed(LoanTypes.Slice storage slice) internal view returns (uint256) {
        uint256 gross = slice.accruedInterest > slice.minInterest ? slice.accruedInterest : slice.minInterest;
        return gross > slice.interestPaid ? gross - slice.interestPaid : 0;
    }

    /// @notice Unpaid interest on a slice as it would stand at `nowTs`, worked out in memory only.
    /// @dev The hub's view functions, `debtOf` among them, rely on this so that quotes and auction targets
    ///      include interest up to the current second. State-changing paths accrue through `settleTo` instead.
    function owedAt(LoanTypes.Slice storage slice, uint40 nowTs) internal view returns (uint256) {
        uint256 accrued = slice.accruedInterest;
        if (nowTs > slice.lastAccrual) accrued += linear(slice.principal, slice.aprBps, nowTs - slice.lastAccrual);
        uint256 gross = accrued > slice.minInterest ? accrued : slice.minInterest;
        return gross > slice.interestPaid ? gross - slice.interestPaid : 0;
    }
}
