// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Minimal {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MockRouter {
    address public factory;
    address public WETH;

    bool public failSwap;
    bool public failAddLiquidity;
    bool public failGetAmountsOut;
    uint256 public quotedAmountOut;
    uint256 public lastAmountOutMin;
    address public lastSwapTokenIn;
    address public lastSwapTokenOut;
    address public lastSwapTo;
    address public lastAddLiquidityTokenA;
    address public lastAddLiquidityTokenB;
    address public lastAddLiquidityTo;

    bytes32[] public swapPathHashes;

    constructor(address factory_) {
        factory = factory_;
        WETH = address(0);
    }

    function setFailSwap(bool value) external {
        failSwap = value;
    }

    function setFailAddLiquidity(bool value) external {
        failAddLiquidity = value;
    }

    function setFailGetAmountsOut(bool value) external {
        failGetAmountsOut = value;
    }

    function setQuotedAmountOut(uint256 amountOut) external {
        quotedAmountOut = amountOut;
    }

    function swapPathHashAt(uint256 index) external view returns (bytes32) {
        return swapPathHashes[index];
    }

    function swapPathHashCount() external view returns (uint256) {
        return swapPathHashes.length;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        if (failGetAmountsOut) {
            revert("Quote failed");
        }
        require(path.length >= 2, "Invalid path");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = quotedAmountOut;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        if (failSwap) {
            revert("Swap failed");
        }
        lastAmountOutMin = amountOutMin;
        lastSwapTokenIn = path[0];
        lastSwapTokenOut = path[path.length - 1];
        lastSwapTo = to;
        swapPathHashes.push(keccak256(abi.encode(path)));
        require(IERC20Minimal(path[0]).transferFrom(msg.sender, address(this), amountIn), "Transfer in failed");
        address tokenOutAddr = path[path.length - 1];
        if (tokenOutAddr.code.length > 0) {
            (bool success,) = tokenOutAddr.call(abi.encodeWithSignature("mint(address,uint256)", to, quotedAmountOut));
            if (!success) {
                require(IERC20Minimal(tokenOutAddr).balanceOf(address(this)) >= quotedAmountOut, "Router balance low");
                require(IERC20Minimal(tokenOutAddr).transfer(to, quotedAmountOut), "Transfer out failed");
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (failAddLiquidity) {
            revert("Add liquidity failed");
        }
        lastAddLiquidityTokenA = tokenA;
        lastAddLiquidityTokenB = tokenB;
        lastAddLiquidityTo = to;
        require(IERC20Minimal(tokenA).transferFrom(msg.sender, address(this), amountADesired), "Transfer A failed");
        require(IERC20Minimal(tokenB).transferFrom(msg.sender, address(this), amountBDesired), "Transfer B failed");
        return (amountADesired, amountBDesired, 1);
    }
}
