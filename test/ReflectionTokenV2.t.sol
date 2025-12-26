// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ReflectionTokenV2} from "../src/ReflectionTokenV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFactory} from "./mocks/MockFactory.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract ToggleRouterFactory {
    address public factoryAddress;
    bool public revertFactory;

    constructor(address factory_) {
        factoryAddress = factory_;
    }

    function setRevertFactory(bool value) external {
        revertFactory = value;
    }

    function factory() external view returns (address) {
        if (revertFactory) {
            revert("factory revert");
        }
        return factoryAddress;
    }
}

contract RevertingPair {
    function token0() external pure returns (address) {
        revert("token0 revert");
    }

    function token1() external pure returns (address) {
        revert("token1 revert");
    }

    function factory() external pure returns (address) {
        revert("factory revert");
    }
}

contract ReflectionTokenV2Test is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);

    ReflectionTokenV2 private token;
    MockFactory private factory;
    MockRouter private router;
    MockERC20 private ankrBnb;
    MockERC20 private wbnb;
    MockERC20 private stable;
    MockPair private pair;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        factory = new MockFactory();
        router = new MockRouter(address(factory));
        ankrBnb = new MockERC20("ankrBNB", "ankrBNB", 18);
        wbnb = new MockERC20("WBNB", "WBNB", 18);
        stable = new MockERC20("USDC", "USDC", 6);

        token = new ReflectionTokenV2(address(ankrBnb));

        token.setFactoryAllowed(address(factory), true);
        token.setRouterAllowed(address(router), true);
        token.setBuybackRouter(address(router));

        token.setHopTokenAllowed(address(wbnb), true);
        token.setHopTokenAllowed(address(ankrBnb), true);
        token.setHopTokenAllowed(address(stable), true);

        address[] memory pathToAnkr = new address[](3);
        pathToAnkr[0] = address(token);
        pathToAnkr[1] = address(wbnb);
        pathToAnkr[2] = address(ankrBnb);
        token.setPath(address(router), address(token), address(ankrBnb), pathToAnkr);

        address[] memory pathToToken = new address[](3);
        pathToToken[0] = address(ankrBnb);
        pathToToken[1] = address(wbnb);
        pathToToken[2] = address(token);
        token.setPath(address(router), address(ankrBnb), address(token), pathToToken);

        pair = new MockPair(address(token), address(ankrBnb), address(factory));
        factory.setPair(address(token), address(ankrBnb), address(pair));
        pair.setReserves(1_000_000e18, 1_000_000e18);

        token.transfer(address(pair), 200_000e18);
        token.setAmmPair(address(pair), address(router), true);
        token.transfer(address(router), 100_000e18);
    }

    function testMetadata() public view {
        assertEq(token.name(), "Basalt");
        assertEq(token.symbol(), "BASLT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000e18);
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

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(pair), alice, amount - expectedFee);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(pair), address(token), expectedContract);

        vm.prank(address(pair));
        token.transfer(alice, amount);

        assertEq(token.tokensForLiquidity(), (amount * 40) / 10_000);
        assertEq(token.tokensForBuyback(), (amount * 40) / 10_000);
    }

    function testBurnTransferNoFee() public {
        uint256 amount = 10_000e18;
        uint256 contractBalanceBefore = token.balanceOf(address(token));
        token.transfer(token.DEAD(), amount);
        assertEq(token.balanceOf(token.DEAD()), amount);
        assertEq(token.balanceOf(address(token)), contractBalanceBefore);
        assertEq(token.tokensForLiquidity(), 0);
        assertEq(token.tokensForBuyback(), 0);
    }

    function testSellAppliesFees() public {
        uint256 amount = 5_000e18;
        token.transfer(alice, amount);

        uint256 expectedFee = (amount * 100) / 10_000;
        uint256 expectedContract = (amount * 80) / 10_000;

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(pair), amount - expectedFee);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(token), expectedContract);

        vm.prank(alice);
        token.transfer(address(pair), amount);

        assertGe(token.balanceOf(address(pair)), 200_000e18 + amount - expectedFee);
        assertEq(token.tokensForLiquidity(), (amount * 40) / 10_000);
        assertEq(token.tokensForBuyback(), (amount * 40) / 10_000);
    }

    function testSwapBackOnSellAddsLiquidityAndBuyback() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(0, 1e18, 2e18);
        _finalizeAndEnableSwaps();

        uint256 sellAmount = 10_000e18;
        token.transfer(alice, 40_000e18);

        vm.prank(alice);
        token.transfer(address(pair), sellAmount);

        assertEq(router.lastAddLiquidityTokenA(), address(token));
        assertEq(router.lastAddLiquidityTokenB(), address(ankrBnb));
        assertEq(router.lastAddLiquidityTo(), token.DEAD());
        assertGt(ankrBnb.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
    }

    function testMultiHopPathUsage() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(0, 5e18, 0);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 20_000e18);

        vm.prank(alice);
        token.transfer(address(pair), 20_000e18);

        vm.warp(1000);
        token.buyback(5e18, 1, block.timestamp + 100);

        bytes32 expectedTokenToAnkr = _hashPath(_buildPath(address(token), address(wbnb), address(ankrBnb)));
        bytes32 expectedAnkrToToken = _hashPath(_buildPath(address(ankrBnb), address(wbnb), address(token)));

        uint256 count = router.swapPathHashCount();
        bool foundTokenToAnkr;
        bool foundAnkrToToken;
        for (uint256 i = 0; i < count; i++) {
            bytes32 hash = router.swapPathHashAt(i);
            if (hash == expectedTokenToAnkr) {
                foundTokenToAnkr = true;
            }
            if (hash == expectedAnkrToToken) {
                foundAnkrToToken = true;
            }
        }

        assertTrue(foundTokenToAnkr, "token->ankr path not used");
        assertTrue(foundAnkrToToken, "ankr->token path not used");
    }

    function testRouterFailureDoesNotRevert() public {
        MockRouter failingRouter = new MockRouter(address(factory));
        token.setRouterAllowed(address(failingRouter), true);
        token.setBuybackRouter(address(failingRouter));

        address[] memory pathToAnkr = new address[](3);
        pathToAnkr[0] = address(token);
        pathToAnkr[1] = address(wbnb);
        pathToAnkr[2] = address(ankrBnb);
        token.setPath(address(failingRouter), address(token), address(ankrBnb), pathToAnkr);

        address[] memory pathToToken = new address[](3);
        pathToToken[0] = address(ankrBnb);
        pathToToken[1] = address(wbnb);
        pathToToken[2] = address(token);
        token.setPath(address(failingRouter), address(ankrBnb), address(token), pathToToken);

        token.setAmmPair(address(pair), address(failingRouter), true);

        failingRouter.setFailSwap(true);
        failingRouter.setFailAddLiquidity(true);

        token.setSwapSettings(1e18, 10_000e18);
        _finalizeAndEnableSwaps();
        token.transfer(alice, 5_000e18);

        vm.prank(alice);
        token.transfer(address(pair), 5_000e18);

        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testRouterRemovalSkipsFactoryCheck() public {
        ToggleRouterFactory toggleRouter = new ToggleRouterFactory(address(factory));
        token.setRouterAllowed(address(toggleRouter), true);

        toggleRouter.setRevertFactory(true);
        token.setRouterAllowed(address(toggleRouter), false);

        assertFalse(token.routerAllowed(address(toggleRouter)));
    }

    function testSetAmmPairRequiresFactoryPairMatch() public {
        MockPair spoofPair = new MockPair(address(token), address(ankrBnb), address(factory));

        vm.expectRevert("Pair not in factory");
        token.setAmmPair(address(spoofPair), address(router), true);
    }

    function testSetAmmPairDisableSkipsPairCalls() public {
        RevertingPair badPair = new RevertingPair();

        token.setAmmPair(address(badPair), address(router), false);

        assertFalse(token.ammPairs(address(badPair)));
        assertEq(token.pairRouter(address(badPair)), address(0));
    }

    function testSetPathRejectsZeroAddress() public {
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = address(0);
        path[2] = address(ankrBnb);

        vm.expectRevert("Zero address in path");
        token.setPath(address(router), address(token), address(ankrBnb), path);
    }

    function testSwapBackBucketAccountingAddLiquidityFailure() public {
        router.setQuotedAmountOut(10e18);
        router.setFailAddLiquidity(true);
        token.setSwapSettings(1e18, 40e18);
        _finalizeAndEnableSwaps();

        uint256 sellAmount = 10_000e18;
        token.transfer(alice, sellAmount);

        vm.prank(alice);
        token.transfer(address(pair), sellAmount);

        assertEq(token.tokensForLiquidity(), 20e18);
        assertEq(token.tokensForBuyback(), 20e18);
        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testSwapBackBucketAccountingSwapFailure() public {
        router.setQuotedAmountOut(10e18);
        router.setFailSwap(true);
        token.setSwapSettings(1e18, 40e18);
        _finalizeAndEnableSwaps();

        uint256 sellAmount = 10_000e18;
        token.transfer(alice, sellAmount);

        vm.prank(alice);
        token.transfer(address(pair), sellAmount);

        assertEq(token.tokensForLiquidity(), 40e18);
        assertEq(token.tokensForBuyback(), 40e18);
        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testFeeCapEnforced() public {
        uint256 totalFee = token.reflectionFeeBps() + token.liquidityFeeBps() + token.buybackFeeBps();
        assertEq(totalFee, 100);
    }

    function testCooldownEnforcedForBuyback() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(1000, 5e18, 0);
        _finalizeAndEnableSwaps();

        uint256 sellAmount = 10_000e18;
        token.transfer(alice, 40_000e18);

        vm.prank(alice);
        token.transfer(address(pair), sellAmount);

        uint256 deadBalance = token.balanceOf(token.DEAD());
        assertEq(deadBalance, 0);

        vm.warp(2000);
        bool first = token.buyback(5e18, 1, block.timestamp + 100);
        assertTrue(first);
        uint256 afterBuyback = token.balanceOf(token.DEAD());
        assertGt(afterBuyback, 0);

        bool second = token.buyback(5e18, 1, block.timestamp + 100);
        assertFalse(second);
    }

    function testSwapDisabledStillAllowsTransfers() public {
        router.setQuotedAmountOut(10e18);
        assertFalse(token.swapEnabled());

        token.transfer(alice, 5_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 5_000e18);

        assertEq(router.swapPathHashCount(), 0);
        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testSwapQuoteFailureDoesNotRevert() public {
        router.setFailGetAmountsOut(true);
        token.setSwapSettings(1e18, 10_000e18);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 5_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 5_000e18);

        assertEq(router.swapPathHashCount(), 0);
        assertEq(token.tokensForLiquidity(), 20e18);
        assertEq(token.tokensForBuyback(), 20e18);
        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testSwapQuoteZeroDoesNotRevert() public {
        router.setQuotedAmountOut(0);
        token.setSwapSettings(1e18, 10_000e18);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 5_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 5_000e18);

        assertEq(router.swapPathHashCount(), 0);
        assertEq(token.tokensForLiquidity(), 20e18);
        assertEq(token.tokensForBuyback(), 20e18);
        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testAddLiquidityFailureDoesNotRevert() public {
        router.setQuotedAmountOut(10e18);
        router.setFailAddLiquidity(true);
        token.setSwapSettings(1e18, 10_000e18);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 10_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 10_000e18);

        assertGt(token.balanceOf(address(pair)), 200_000e18);
    }

    function testFinalizeConfigLocksChanges() public {
        token.finalizeConfig();

        vm.expectRevert("Config finalized");
        token.setFactoryAllowed(address(factory), false);

        vm.expectRevert("Config finalized");
        token.setRouterAllowed(address(router), false);

        vm.expectRevert("Config finalized");
        token.setAmmPair(address(pair), address(router), false);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(ankrBnb);

        vm.expectRevert("Config finalized");
        token.setPath(address(router), address(token), address(ankrBnb), path);

        vm.expectRevert("Config finalized");
        token.setSwapSettings(2e18, 10_000e18);

        vm.expectRevert("Config finalized");
        token.setSlippageBps(200);

        vm.expectRevert("Config finalized");
        token.setBuybackSettings(0, 1e18, 2e18);

        vm.expectRevert("Config finalized");
        token.setHopTokenAllowed(address(wbnb), false);

        vm.expectRevert("Config finalized");
        token.setMaxBuybackPriceImpactBps(300);
    }

    function testFinalizeConfigAllowsSwapDisableOnly() public {
        token.finalizeConfig();
        token.setSwapEnabled(true);
        token.setSwapEnabled(false);
        assertFalse(token.swapEnabled());

        vm.expectRevert("Swap enable locked");
        token.setSwapEnabled(true);
    }

    function testBuybackPriceImpactCapSkips() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(0, 5e18, 0);
        token.setMaxBuybackPriceImpactBps(50);
        _finalizeAndEnableSwaps();

        pair.setReserves(1e18, 1e18);

        token.transfer(alice, 21_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 20_000e18);

        bytes32 expectedBuybackPath = _hashPath(_buildPath(address(ankrBnb), address(wbnb), address(token)));
        assertEq(_countSwapPath(expectedBuybackPath), 0);

        bool success = token.buyback(5e18, 1, block.timestamp + 100);
        assertFalse(success);
        assertEq(_countSwapPath(expectedBuybackPath), 0);
    }

    function testRenounceOwnershipLocksAdmin() public {
        token.renounceOwnership();

        vm.expectRevert("Not owner");
        token.setSwapEnabled(false);

        vm.expectRevert("Not owner");
        token.finalizeConfig();

        uint256 amount = 1_000e18;
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function testSlippageBounded() public {
        vm.expectRevert("Slippage too high");
        token.setSlippageBps(501);
    }

    function testRateGuardrails() public {
        bytes32 rTotalSlot = bytes32(uint256(3));
        vm.store(address(token), rTotalSlot, bytes32(uint256(0)));
        assertEq(token.getRate(), 1);
    }

    function testReflectionStressInvariants() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 500e18);
        token.setBuybackSettings(0, 10e18, 0);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 50_000e18);
        token.transfer(bob, 50_000e18);

        for (uint256 i = 0; i < 20; i++) {
            vm.prank(address(pair));
            token.transfer(alice, 1_000e18);
            vm.prank(address(pair));
            token.transfer(bob, 1_000e18);
            vm.prank(alice);
            token.transfer(address(pair), 800e18);
            vm.prank(bob);
            token.transfer(address(pair), 800e18);
        }

        assertEq(token.totalSupply(), 1_000_000e18);

        uint256 rate = token.getRate();
        uint256 amount = 12_345e18;
        uint256 reflected = amount * rate;
        uint256 recovered = token.tokenFromReflection(reflected);
        assertApproxEqAbs(recovered, amount, 1);

        uint256 sumBalances = token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob)
            + token.balanceOf(address(pair)) + token.balanceOf(address(token)) + token.balanceOf(address(router))
            + token.balanceOf(token.DEAD());
        assertApproxEqAbs(sumBalances, token.totalSupply(), 10);
    }

    function testFinalizeConfigRequiresBeforeEnable() public {
        vm.expectRevert("Config not finalized");
        token.setSwapEnabled(true);
    }

    function testBuybackRespectsCapsAndMinOut() public {
        router.setQuotedAmountOut(10e18);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(0, 2e18, 0);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 21_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 20_000e18);

        vm.warp(1000);
        bool success = token.buyback(5e18, 9e18, block.timestamp + 100);
        assertTrue(success);
        assertEq(router.lastAmountOutMin(), 9.9e18);
        assertGt(token.balanceOf(token.DEAD()), 0);
    }

    function testBuybackSwapFailureDoesNotAffectTransfers() public {
        router.setQuotedAmountOut(10e18);
        router.setFailSwap(true);
        token.setSwapSettings(1e18, 10_000e18);
        token.setBuybackSettings(0, 5e18, 0);
        _finalizeAndEnableSwaps();

        token.transfer(alice, 21_000e18);
        vm.prank(alice);
        token.transfer(address(pair), 20_000e18);

        vm.warp(1000);
        bool success = token.buyback(5e18, 1, block.timestamp + 100);
        assertFalse(success);

        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
    }

    function _buildPath(address a, address b, address c) private pure returns (address[] memory path) {
        path = new address[](3);
        path[0] = a;
        path[1] = b;
        path[2] = c;
    }

    function _hashPath(address[] memory path) private pure returns (bytes32) {
        return keccak256(abi.encode(path));
    }

    function _countSwapPath(bytes32 expectedHash) private view returns (uint256 count) {
        uint256 total = router.swapPathHashCount();
        for (uint256 i = 0; i < total; i++) {
            if (router.swapPathHashAt(i) == expectedHash) {
                count++;
            }
        }
    }

    function _finalizeAndEnableSwaps() private {
        token.finalizeConfig();
        token.setSwapEnabled(true);
    }
}
