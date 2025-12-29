// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {PureReflectionToken, IERC20} from "../src/PureReflectionToken.sol";

contract PureReflectionTokenHarness is PureReflectionToken {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 totalSupplyTokens,
        address initialHolder
    ) PureReflectionToken(name_, symbol_, decimals_, totalSupplyTokens, initialHolder) {}

    function exposedGetRate() external view returns (uint256) {
        return _getRate();
    }
}

contract PureReflectionTokenTest is Test {
    PureReflectionToken private token;

    address private initialHolder;
    address private alice;
    address private bob;
    address private spender;

    uint256 private constant TOTAL_SUPPLY = 1_000e18;
    uint256 private constant DEAD_SUPPLY = 900e18;
    uint256 private constant HOLDER_SUPPLY = 100e18;
    uint256 private constant TOLERANCE = 2;

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
        initialHolder = makeAddr("initialHolder");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new PureReflectionToken("Basalt", "BSLT", 18, TOTAL_SUPPLY, initialHolder);
    }

    function testMetadata() public {
        assertEq(token.name(), "Basalt");
        assertEq(token.symbol(), "BSLT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function testDeploymentSplitAndEvents() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), token.DEAD(), DEAD_SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), initialHolder, HOLDER_SUPPLY);
        PureReflectionToken deployed = new PureReflectionToken("Basalt", "BSLT", 18, TOTAL_SUPPLY, initialHolder);

        assertEq(deployed.totalSupply(), TOTAL_SUPPLY);
        assertEq(deployed.balanceOf(initialHolder), HOLDER_SUPPLY);
        assertEq(deployed.balanceOf(deployed.DEAD()), DEAD_SUPPLY);
    }

    function testDeploymentMergesDeadHolderAllocation() public {
        address dead = token.DEAD();

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), dead, DEAD_SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), dead, HOLDER_SUPPLY);
        PureReflectionToken deployed = new PureReflectionToken("Basalt", "BSLT", 18, TOTAL_SUPPLY, dead);

        assertEq(deployed.totalSupply(), TOTAL_SUPPLY);
        assertEq(deployed.balanceOf(dead), TOTAL_SUPPLY);
    }

    function testDeploymentRevertsOnZeroSupply() public {
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroTotalSupply.selector));
        new PureReflectionToken("Token", "TKN", 18, 0, initialHolder);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 50e18;
        uint256 spend = 20e18;

        vm.prank(initialHolder);
        token.approve(spender, amount);
        assertEq(token.allowance(initialHolder, spender), amount);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(initialHolder, spender, amount - spend);
        vm.prank(spender);
        token.transferFrom(initialHolder, alice, spend);

        assertEq(token.allowance(initialHolder, spender), amount - spend);
    }

    function testGetRateNeverReturnsZero() public {
        PureReflectionTokenHarness harness =
            new PureReflectionTokenHarness("Basalt", "BSLT", 18, TOTAL_SUPPLY, initialHolder);

        vm.store(address(harness), bytes32(uint256(2)), bytes32(uint256(0)));
        assertEq(harness.exposedGetRate(), 1);
    }

    function testFeeCapsAtReflectionFloor() public {
        uint256 tTotal = token.totalSupply();
        uint256 rTotal = tTotal + 5;

        vm.store(address(token), bytes32(uint256(2)), bytes32(rTotal));

        bytes32 holderSlot = keccak256(abi.encode(initialHolder, uint256(3)));
        vm.store(address(token), holderSlot, bytes32(rTotal));

        uint256 amount = 100e18;
        uint256 expectedTransfer = amount - 5;

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(initialHolder, alice, expectedTransfer);
        vm.prank(initialHolder);
        token.transfer(alice, amount);

        uint256 rTotalAfter = uint256(vm.load(address(token), bytes32(uint256(2))));
        assertEq(rTotalAfter, tTotal);
    }

    function testTransferFromRevertsWhenAllowanceExceeded() public {
        uint256 amount = 50e18;

        vm.prank(initialHolder);
        token.approve(spender, amount);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.AllowanceExceeded.selector));
        token.transferFrom(initialHolder, alice, amount + 1);
    }

    function testBasicTransferFee() public {
        uint256 amount = 10e18;
        uint256 fee = (amount * token.FEE_BPS()) / token.BPS_DENOM();
        uint256 tTransfer = amount - fee;
        uint256 tTotal = token.totalSupply();

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(initialHolder, alice, tTransfer);
        vm.prank(initialHolder);
        token.transfer(alice, amount);

        uint256 expectedBalance = _expectedBalanceAfterReceiver(0, tTransfer, fee, tTotal);
        assertApproxEqAbs(token.balanceOf(alice), expectedBalance, TOLERANCE);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function testReflectionsIncreaseNonParticipantBalance() public {
        uint256 give = 40e18;

        vm.startPrank(initialHolder);
        token.transfer(alice, give);
        token.transfer(bob, give);
        vm.stopPrank();

        uint256 a0 = token.balanceOf(alice);
        uint256 b0 = token.balanceOf(bob);
        uint256 holder0 = token.balanceOf(initialHolder);

        uint256 amount = 10e18;
        uint256 fee = (amount * token.FEE_BPS()) / token.BPS_DENOM();
        uint256 tTransfer = amount - fee;
        uint256 tTotal = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 a1 = token.balanceOf(alice);
        uint256 b1 = token.balanceOf(bob);
        uint256 holder1 = token.balanceOf(initialHolder);

        assertGe(holder1, holder0);
        assertGe(b1, b0 + tTransfer);

        uint256 expectedAlice = _expectedBalanceAfterSender(a0, amount, fee, tTotal);
        uint256 expectedBob = _expectedBalanceAfterReceiver(b0, tTransfer, fee, tTotal);
        assertApproxEqAbs(a1, expectedAlice, TOLERANCE);
        assertApproxEqAbs(b1, expectedBob, TOLERANCE);
    }

    function testDeadReceivesReflections() public {
        uint256 deadBefore = token.balanceOf(token.DEAD());

        vm.prank(initialHolder);
        token.transfer(alice, 25e18);

        uint256 deadAfter = token.balanceOf(token.DEAD());
        assertGt(deadAfter, deadBefore);
    }

    function testZeroAmountTransfer() public {
        uint256 holderBefore = token.balanceOf(initialHolder);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(initialHolder, alice, 0);
        vm.prank(initialHolder);
        token.transfer(alice, 0);

        assertEq(token.balanceOf(initialHolder), holderBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
    }

    function testZeroAddressProtections() public {
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        new PureReflectionToken("Token", "TKN", 18, 1_000e18, address(0));

        vm.prank(initialHolder);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.approve(address(0), 1);

        vm.prank(initialHolder);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.transfer(address(0), 1);

        vm.prank(initialHolder);
        token.approve(spender, 100e18);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.transferFrom(initialHolder, address(0), 10e18);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(PureReflectionToken.ZeroAddress.selector));
        token.transfer(alice, 1);
    }

    function testNoAdminFunctionsExist() public {
        (bool successOwner,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool successExclude,) = address(token).call(abi.encodeWithSignature("excludeFromFee(address)", alice));
        assertFalse(successOwner);
        assertFalse(successExclude);
    }

    function testFuzzTransfersMaintainSupply(uint256 seed) public {
        vm.startPrank(initialHolder);
        token.transfer(alice, 30e18);
        token.transfer(bob, 20e18);
        vm.stopPrank();

        address[] memory actors = new address[](4);
        actors[0] = initialHolder;
        actors[1] = alice;
        actors[2] = bob;
        actors[3] = token.DEAD();

        for (uint256 i = 0; i < 12; i++) {
            uint256 fromIndex = uint256(keccak256(abi.encode(seed, i, "from"))) % actors.length;
            uint256 toIndex = uint256(keccak256(abi.encode(seed, i, "to"))) % actors.length;
            address from = actors[fromIndex];
            address to = actors[toIndex];

            uint256 balance = token.balanceOf(from);
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i, "amount"))), 0, balance);

            vm.prank(from);
            token.transfer(to, amount);
        }

        uint256 sumBalances = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sumBalances += token.balanceOf(actors[i]);
        }

        assertLe(sumBalances, token.totalSupply());
    }
}
