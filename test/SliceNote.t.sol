// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {SliceNote} from "../src/SliceNote.sol";

/// @notice Tests for refreshing slice note metadata without a base URI change.
contract SliceNoteTest is BaseTest {
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function test_governanceCanRefreshARange() public {
        vm.expectEmit(address(sliceNote));
        emit BatchMetadataUpdate(1, 50);
        vm.prank(gov);
        sliceNote.refreshMetadata(1, 50);
    }

    function test_refreshMetadataChecksCallerAndRange() public {
        vm.prank(lender1);
        vm.expectRevert(SliceNote.NotGovernance.selector);
        sliceNote.refreshMetadata(1, 50);

        vm.prank(gov);
        vm.expectRevert(SliceNote.InvalidRange.selector);
        sliceNote.refreshMetadata(50, 1);
    }
}
