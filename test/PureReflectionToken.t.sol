// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {PureReflectionToken, IERC20} from "../src/PureReflectionToken.sol";

contract PureReflectionTokenTest is Test {
    PureReflectionToken private token;

    address private owner;
    address private alice;
    address private bob;
    address private spender;

    uint256 private constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 private constant TOLERANCE = 10;

    function _expectedBalanceAfterSender(uint256 balanceBefore, uint256 tAmount, uint256 tFee, uint256 tTotal)
        private
        pure
        returns (uint256)
    {
        uint256 newBase = balanceBefore - tAmount;
        return (newBase * tTotal) / (tTotal - tFee);
    }

    function _expectedBalanceAfterReceiver(uint256 balanceBefore, uint256 tTransfer, uint256 tFee, uint256 tTotal)
        private
        pure
        returns (uint256)
    {
        uint256 newBase = balanceBefore + tTransfer;
        return (newBase * tTotal) / (tTotal - tFee);
    }

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new PureReflectionToken("Pure Reflection", "PURE", 18, TOTAL_SUPPLY, owner);
    }

    function testDeployment() public {
        address initialHolder = makeAddr("initialHolder");
        uint256 supply = 500_000e18;

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), initialHolder, supply);
        PureReflectionToken deployed = new PureReflectionToken("Token", "TKN", 6, supply, initialHolder);

        assertEq(deployed.name(), "Token");
        assertEq(deployed.symbol(), "TKN");
        assertEq(deployed.decimals(), 6);
        assertEq(deployed.totalSupply(), supply);
        assertEq(deployed.balanceOf(initialHolder), supply);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1_000e18;
        uint256 spend = 400e18;

        vm.prank(owner);
        token.approve(spender, amount);
        assertEq(token.allowance(owner, spender), amount);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(owner, spender, amount - spend);
        vm.prank(spender);
        token.transferFrom(owner, alice, spend);

        assertEq(token.allowance(owner, spender), amount - spend);
    }

    function testTransferFromRevertsWhenAllowanceExceeded() public {
        uint256 amount = 1_000e18;

        vm.prank(owner);
        token.approve(spender, amount);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.AllowanceExceeded.selector));
        token.transferFrom(owner, alice, amount + 1);
    }

    function testBasicTransferFee() public {
        uint256 amount = 10_000e18;
        uint256 fee = (amount * token.FEE_BPS()) / token.BPS_DENOM();
        uint256 tTransfer = amount - fee;
        uint256 tTotal = token.totalSupply();

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(owner, alice, tTransfer);
        vm.prank(owner);
        token.transfer(alice, amount);

        uint256 expectedBalance = _expectedBalanceAfterReceiver(0, tTransfer, fee, tTotal);
        assertApproxEqAbs(token.balanceOf(alice), expectedBalance, TOLERANCE);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function testReflectionsIncreaseNonParticipantBalance() public {
        uint256 give = 100_000e18;

        vm.startPrank(owner);
        token.transfer(alice, give);
        token.transfer(bob, give);
        vm.stopPrank();

        uint256 a0 = token.balanceOf(alice);
        uint256 b0 = token.balanceOf(bob);
        uint256 o0 = token.balanceOf(owner);

        uint256 amount = 10_000e18;
        uint256 fee = (amount * token.FEE_BPS()) / token.BPS_DENOM();
        uint256 tTransfer = amount - fee;
        uint256 tTotal = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 a1 = token.balanceOf(alice);
        uint256 b1 = token.balanceOf(bob);
        uint256 o1 = token.balanceOf(owner);

        assertGe(o1, o0);
        assertGe(b1, b0 + tTransfer);

        uint256 expectedAlice = _expectedBalanceAfterSender(a0, amount, fee, tTotal);
        uint256 expectedBob = _expectedBalanceAfterReceiver(b0, tTransfer, fee, tTotal);
        assertApproxEqAbs(a1, expectedAlice, TOLERANCE);
        assertApproxEqAbs(b1, expectedBob, TOLERANCE);
    }

    function testMultipleTransfersAccumulateReflections() public {
        uint256 give = 200_000e18;

        vm.startPrank(owner);
        token.transfer(alice, give);
        token.transfer(bob, give);
        vm.stopPrank();

        uint256 baseline = token.balanceOf(owner);
        uint256 amount = 1_000e18;

        for (uint256 i = 0; i < 8; i++) {
            vm.prank(alice);
            token.transfer(bob, amount);
            vm.prank(bob);
            token.transfer(alice, amount);
        }

        uint256 finalBalance = token.balanceOf(owner);
        assertGe(finalBalance, baseline + 1);
    }

    function testZeroAmountTransfer() public {
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(owner, alice, 0);
        vm.prank(owner);
        token.transfer(alice, 0);

        assertEq(token.balanceOf(owner), ownerBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
    }

    function testZeroAddressProtections() public {
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        new PureReflectionToken("Token", "TKN", 18, 1_000e18, address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.approve(address(0), 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.transfer(address(0), 1);

        vm.prank(owner);
        token.approve(spender, 100e18);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.transferFrom(owner, address(0), 10e18);
    }
}
