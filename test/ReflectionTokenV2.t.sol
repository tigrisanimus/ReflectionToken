// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ReflectionTokenV2} from "../src/ReflectionTokenV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFactory} from "./mocks/MockFactory.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract ReflectionTokenV2Test is Test {
    ReflectionTokenV2 private token;
    MockFactory private factory;
    MockRouter private router;
    MockERC20 private ankrBnb;
    MockERC20 private stable;
    MockPair private pair;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        factory = new MockFactory();
        router = new MockRouter(address(factory));
        ankrBnb = new MockERC20("ankrBNB", "ankrBNB", 18);
        stable = new MockERC20("USDC", "USDC", 6);

        token = new ReflectionTokenV2("Reflection V2", "RV2", 1_000_000e18, 500e18, 5_000e18);

        token.setFactoryAllowed(address(factory), true);
        token.setRouterAllowed(address(router), true);

        token.setBackingTokenAllowed(address(ankrBnb), true);
        token.setBackingTokenAllowed(address(stable), true);

        pair = new MockPair(address(token), address(ankrBnb), address(factory));
        factory.setPair(address(token), address(ankrBnb), address(pair));

        token.transfer(address(pair), 200_000e18);
        token.setAmmPair(address(pair), address(router), true);
    }

    function testWalletTransferNoFee() public {
        uint256 amount = 10_000e18;
        uint256 contractBalanceBefore = token.balanceOf(address(token));
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(token)), contractBalanceBefore);
        assertEq(token.tokensForLiquidity(), 0);
        assertEq(token.tokensForBuyback(), 0);
    }

    function testBuyAppliesFeesAndSplits() public {
        uint256 amount = 10_000e18;
        uint256 expectedFee = (amount * 100) / 10_000;
        uint256 expectedContract = (amount * 80) / 10_000;

        vm.prank(address(pair));
        token.transfer(alice, amount);

        assertGe(token.balanceOf(alice), amount - expectedFee);
        assertGe(token.balanceOf(address(token)), expectedContract);
        assertEq(token.tokensForLiquidity(), (amount * 40) / 10_000);
        assertEq(token.tokensForBuyback(), (amount * 40) / 10_000);
    }

    function testSellAppliesFees() public {
        uint256 amount = 5_000e18;
        token.transfer(alice, amount);

        vm.prank(alice);
        token.transfer(address(pair), amount);

        uint256 expectedFee = (amount * 100) / 10_000;
        assertGe(token.balanceOf(address(pair)), 200_000e18 + amount - expectedFee);
        assertEq(token.tokensForLiquidity(), (amount * 40) / 10_000);
        assertEq(token.tokensForBuyback(), (amount * 40) / 10_000);
    }

    function testNonRegisteredPairNoFees() public {
        MockPair otherPair = new MockPair(address(token), address(stable), address(factory));
        uint256 amount = 1_000e18;
        token.transfer(address(otherPair), amount);

        vm.prank(address(otherPair));
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.tokensForLiquidity(), 0);
        assertEq(token.tokensForBuyback(), 0);
    }

    function testFeeCapEnforced() public {
        vm.expectRevert("Fee cap");
        token.setFees(50, 40, 20);
    }

    function testSwapbackRouterFailureDoesNotRevert() public {
        MockRouter failingRouter = new MockRouter(address(factory));
        token.setRouterAllowed(address(failingRouter), true);
        token.setAmmPair(address(pair), address(failingRouter), true);

        ReflectionTokenV2.PoolConfig[] memory configs = new ReflectionTokenV2.PoolConfig[](1);
        configs[0] = ReflectionTokenV2.PoolConfig({
            pair: address(pair),
            router: address(failingRouter),
            backingToken: address(ankrBnb),
            weightBps: 10_000,
            enabled: true
        });
        token.configurePools(configs);

        failingRouter.setFailSwap(true);
        failingRouter.setFailAddLiquidity(true);

        token.setSwapSettings(1e18, 10_000e18);
        token.transfer(alice, 5_000e18);

        vm.prank(alice);
        token.transfer(address(pair), 5_000e18);

        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testRoundRobinPoolProcessingRespectsMax() public {
        MockRouter routerTwo = new MockRouter(address(factory));
        token.setRouterAllowed(address(routerTwo), true);

        ReflectionTokenV2.PoolConfig[] memory configs = new ReflectionTokenV2.PoolConfig[](2);
        configs[0] = ReflectionTokenV2.PoolConfig({
            pair: address(pair),
            router: address(router),
            backingToken: address(ankrBnb),
            weightBps: 5_000,
            enabled: true
        });
        configs[1] = ReflectionTokenV2.PoolConfig({
            pair: address(pair),
            router: address(routerTwo),
            backingToken: address(stable),
            weightBps: 5_000,
            enabled: true
        });
        token.configurePools(configs);
        token.setMaxPoolsProcessed(1);
        router.setQuotedAmountOut(1000);
        routerTwo.setQuotedAmountOut(1000);

        token.setSwapSettings(1e18, 10_000e18);
        token.transfer(alice, 10_000e18);

        vm.prank(alice);
        token.transfer(address(pair), 10_000e18);

        bool firstCalled = router.lastAddLiquidityTokenA() == address(token);
        bool secondCalled = routerTwo.lastAddLiquidityTokenA() == address(token);
        assertTrue(firstCalled != secondCalled, "Only one pool processed");
        assertEq(token.poolCursor(), 1);
    }

    function testBuybackUsesAnkrBnbBudgetAndCooldown() public {
        token.setBuybackAnkrBnb(address(ankrBnb));
        token.setBuybackRouter(address(router));
        token.setBuybackSettings(100, 50e18, 0);
        router.setQuotedAmountOut(1000);

        ankrBnb.mint(address(token), 200e18);
        token.transfer(address(router), 100_000e18);

        vm.warp(1000);
        token.triggerBuyback();

        assertEq(ankrBnb.balanceOf(address(token)), 150e18);
        assertEq(router.lastSwapTokenIn(), address(ankrBnb));

        token.triggerBuyback();

        assertEq(ankrBnb.balanceOf(address(token)), 150e18);
    }

    function testSlippageBpsAppliedToAmountOutMin() public {
        token.setFees(0, 100, 0);
        ReflectionTokenV2.PoolConfig[] memory configs = new ReflectionTokenV2.PoolConfig[](1);
        configs[0] = ReflectionTokenV2.PoolConfig({
            pair: address(pair),
            router: address(router),
            backingToken: address(ankrBnb),
            weightBps: 10_000,
            enabled: true
        });
        token.configurePools(configs);
        token.setSlippageBps(100);
        router.setQuotedAmountOut(1000);

        token.setSwapSettings(1e18, 10_000e18);
        token.transfer(alice, 10_000e18);

        vm.prank(alice);
        token.transfer(address(pair), 10_000e18);

        assertEq(router.lastAmountOutMin(), 990);
    }

    function testSetAmmPairValidatesFactoryAndTokens() public {
        MockFactory otherFactory = new MockFactory();
        MockPair badPair = new MockPair(address(ankrBnb), address(stable), address(otherFactory));

        vm.expectRevert("Pair missing token");
        token.setAmmPair(address(badPair), address(router), true);

        MockPair wrongFactoryPair = new MockPair(address(token), address(ankrBnb), address(otherFactory));
        vm.expectRevert("Pair factory not allowed");
        token.setAmmPair(address(wrongFactoryPair), address(router), true);
    }
}
