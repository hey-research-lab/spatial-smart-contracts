// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "../src/mocks/Mocks.sol";

/// @notice Tests for the fee vault's batch withdrawal and balance view.
contract FeeVaultTest is BaseTest {
    MockERC20 internal other;

    function setUp() public override {
        super.setUp();
        other = new MockERC20("Other", "OTH", 18);
        usdg.mint(address(feeVault), 500e6);
        other.mint(address(feeVault), 7e18);
    }

    function test_withdrawManySweepsEachToken() public {
        address treasury = makeAddr("treasury");
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdg));
        tokens[1] = IERC20(address(other));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 200e6;
        amounts[1] = type(uint256).max;

        vm.prank(gov);
        feeVault.withdrawMany(tokens, treasury, amounts);

        assertEq(usdg.balanceOf(treasury), 200e6);
        assertEq(other.balanceOf(treasury), 7e18);
        assertEq(feeVault.balanceOf(IERC20(address(usdg))), 300e6);
        assertEq(feeVault.balanceOf(IERC20(address(other))), 0);
    }

    function test_withdrawManyChecksCallerAndInputs() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdg));
        tokens[1] = IERC20(address(other));
        uint256[] memory amounts = new uint256[](1);

        vm.prank(lender1);
        vm.expectRevert(FeeVault.NotGovernance.selector);
        feeVault.withdrawMany(tokens, lender1, amounts);

        vm.prank(gov);
        vm.expectRevert(FeeVault.ZeroRecipient.selector);
        feeVault.withdrawMany(tokens, address(0), amounts);

        vm.prank(gov);
        vm.expectRevert(FeeVault.LengthMismatch.selector);
        feeVault.withdrawMany(tokens, gov, amounts);
    }
}
