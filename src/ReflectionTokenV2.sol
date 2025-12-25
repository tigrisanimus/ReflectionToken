// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract ReflectionTokenV2 is IERC20, Ownable {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 private constant MAX = type(uint256).max;
    uint256 private constant BPS_DENOM = 10_000;
    address public constant DEAD = address(0xdead);

    uint256 private immutable _tTotal;
    uint256 private _rTotal;

    mapping(address => uint256) private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint16 public reflectionFeeBps = 20;
    uint16 public liquidityFeeBps = 40;
    uint16 public buybackFeeBps = 40;
    uint16 public constant MAX_TOTAL_FEE_BPS = 100;

    mapping(address => bool) public ammPairs;
    mapping(address => bool) public routerAllowed;
    mapping(address => bool) public factoryAllowed;
    mapping(address => address) public pairRouter;

    mapping(address => bool) public backingTokenAllowed;
    address public buybackAnkrBnb;
    address public buybackRouter;

    struct PoolConfig {
        address pair;
        address router;
        address backingToken;
        uint16 weightBps;
        bool enabled;
    }

    PoolConfig[] public pools;
    uint256 public poolCursor;
    uint256 public maxPoolsProcessedPerSwap = 2;

    uint256 public swapThreshold;
    uint256 public maxSwapAmount;
    uint16 public slippageBps = 50;

    uint256 public tokensForLiquidity;
    uint256 public tokensForBuyback;

    bool private _inSwap;

    uint256 public buybackCooldownSeconds = 1 hours;
    uint256 public maxBuybackAnkrBnb;
    uint256 public buybackUpperLimitAnkrBnb;
    uint256 public lastBuybackTimestamp;

    event FeesUpdated(uint16 reflectionFeeBps, uint16 liquidityFeeBps, uint16 buybackFeeBps);
    event SwapBack(uint256 tokensSwapped);
    event Buyback(address indexed router, uint256 amountIn);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint256 swapThreshold_,
        uint256 maxSwapAmount_
    ) {
        require(totalSupply_ > 0, "Supply zero");
        name = name_;
        symbol = symbol_;
        _tTotal = totalSupply_;
        _rTotal = MAX - (MAX % totalSupply_);

        _rOwned[msg.sender] = _rTotal;
        emit Transfer(address(0), msg.sender, totalSupply_);

        swapThreshold = swapThreshold_;
        maxSwapAmount = maxSwapAmount_;
        _enforceFeeCap(reflectionFeeBps, liquidityFeeBps, buybackFeeBps);
    }

    function totalSupply() external view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return tokenFromReflection(_rOwned[account]);
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "Allowance");
        _approve(sender, msg.sender, currentAllowance - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _rTotal, "rAmount>rTotal");
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    function getRate() external view returns (uint256) {
        return _getRate();
    }

    function setFees(uint16 reflectionFee, uint16 liquidityFee, uint16 buybackFee) external onlyOwner {
        _enforceFeeCap(reflectionFee, liquidityFee, buybackFee);
        reflectionFeeBps = reflectionFee;
        liquidityFeeBps = liquidityFee;
        buybackFeeBps = buybackFee;
        emit FeesUpdated(reflectionFee, liquidityFee, buybackFee);
    }

    function setFactoryAllowed(address factory, bool allowed) external onlyOwner {
        factoryAllowed[factory] = allowed;
    }

    function setRouterAllowed(address router, bool allowed) external onlyOwner {
        require(factoryAllowed[IUniswapV2Router02(router).factory()], "Factory not allowed");
        routerAllowed[router] = allowed;
    }

    function setAmmPair(address pair, address router, bool allowed) external onlyOwner {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        require(token0 == address(this) || token1 == address(this), "Pair missing token");
        require(factoryAllowed[IUniswapV2Pair(pair).factory()], "Pair factory not allowed");
        require(routerAllowed[router], "Router not allowed");

        ammPairs[pair] = allowed;
        pairRouter[pair] = router;
    }

    function setBackingTokenAllowed(address token, bool allowed) external onlyOwner {
        backingTokenAllowed[token] = allowed;
    }

    function setBuybackAnkrBnb(address ankrBnb) external onlyOwner {
        require(buybackAnkrBnb == address(0), "Buyback token set");
        require(backingTokenAllowed[ankrBnb], "Token not allowed");
        buybackAnkrBnb = ankrBnb;
    }

    function setBuybackRouter(address router) external onlyOwner {
        require(routerAllowed[router], "Router not allowed");
        buybackRouter = router;
    }

    function configurePools(PoolConfig[] calldata configs) external onlyOwner {
        delete pools;
        uint256 totalWeight;
        for (uint256 i = 0; i < configs.length; i++) {
            require(routerAllowed[configs[i].router], "Router not allowed");
            require(backingTokenAllowed[configs[i].backingToken], "Backing token not allowed");
            if (configs[i].enabled) {
                totalWeight += configs[i].weightBps;
            }
            pools.push(configs[i]);
        }
        require(totalWeight == BPS_DENOM, "Weights must sum 100%");
        poolCursor = 0;
    }

    function setSwapSettings(uint256 threshold, uint256 maxSwap) external onlyOwner {
        swapThreshold = threshold;
        maxSwapAmount = maxSwap;
    }

    function setMaxPoolsProcessed(uint256 maxPools) external onlyOwner {
        maxPoolsProcessedPerSwap = maxPools;
    }

    function setSlippageBps(uint16 newSlippage) external onlyOwner {
        require(newSlippage <= 1_000, "Slippage too high");
        slippageBps = newSlippage;
    }

    function setBuybackSettings(uint256 cooldownSeconds, uint256 maxPerCall, uint256 upperLimit) external onlyOwner {
        buybackCooldownSeconds = cooldownSeconds;
        maxBuybackAnkrBnb = maxPerCall;
        buybackUpperLimitAnkrBnb = upperLimit;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function triggerBuyback() external {
        _executeBuyback();
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0) && spender != address(0), "Zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0, "Amount zero");

        bool takeFee = ammPairs[from] || ammPairs[to];

        if (takeFee) {
            _tokenTransferWithFee(from, to, amount);
        } else {
            _tokenTransferNoFee(from, to, amount);
        }

        if (!_inSwap && ammPairs[to]) {
            uint256 contractTokenBalance = balanceOf(address(this));
            if (contractTokenBalance >= swapThreshold) {
                _swapBack(contractTokenBalance);
            }
        }
    }

    function _tokenTransferNoFee(address sender, address recipient, uint256 tAmount) internal {
        uint256 currentRate = _getRate();
        uint256 rAmount = tAmount * currentRate;
        _rOwned[sender] -= rAmount;
        _rOwned[recipient] += rAmount;
        emit Transfer(sender, recipient, tAmount);
    }

    function _tokenTransferWithFee(address sender, address recipient, uint256 tAmount) internal {
        uint256 currentRate = _getRate();
        uint256 tFee = (tAmount * reflectionFeeBps) / BPS_DENOM;
        uint256 tLiquidity = (tAmount * liquidityFeeBps) / BPS_DENOM;
        uint256 tBuyback = (tAmount * buybackFeeBps) / BPS_DENOM;
        uint256 tTransferAmount = tAmount - tFee - tLiquidity - tBuyback;

        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rLiquidity = (tLiquidity + tBuyback) * currentRate;
        uint256 rTransferAmount = rAmount - rFee - rLiquidity;

        _rOwned[sender] -= rAmount;
        _rOwned[recipient] += rTransferAmount;
        _rOwned[address(this)] += rLiquidity;
        tokensForLiquidity += tLiquidity;
        tokensForBuyback += tBuyback;

        _reflectFee(rFee);
        emit Transfer(sender, recipient, tTransferAmount);
        if (tLiquidity + tBuyback > 0) {
            emit Transfer(sender, address(this), tLiquidity + tBuyback);
        }
    }

    function _reflectFee(uint256 rFee) internal {
        _rTotal -= rFee;
    }

    function _getRate() internal view returns (uint256) {
        return _rTotal / _tTotal;
    }

    function _swapBack(uint256 contractTokenBalance) internal {
        if (_inSwap) {
            return;
        }
        uint256 totalTokensToSwap = tokensForLiquidity + tokensForBuyback;
        if (totalTokensToSwap == 0) {
            return;
        }
        uint256 swapAmount = contractTokenBalance;
        if (swapAmount > maxSwapAmount) {
            swapAmount = maxSwapAmount;
        }
        if (swapAmount > totalTokensToSwap) {
            swapAmount = totalTokensToSwap;
        }
        if (swapAmount == 0) {
            return;
        }

        _inSwap = true;
        uint256 liquidityPortion = (swapAmount * tokensForLiquidity) / totalTokensToSwap;
        uint256 buybackPortion = swapAmount - liquidityPortion;

        uint256 liquidityUsed = _processLiquidity(liquidityPortion);
        uint256 buybackUsed = _processBuybackSwap(buybackPortion);

        tokensForLiquidity -= liquidityUsed;
        tokensForBuyback -= buybackUsed;
        _inSwap = false;

        emit SwapBack(swapAmount);
    }

    function _processLiquidity(uint256 amount) internal returns (uint256 used) {
        if (amount == 0) {
            return 0;
        }
        uint256 enabledPools;
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].enabled) {
                enabledPools++;
            }
        }
        if (enabledPools == 0) {
            return 0;
        }

        uint256 processed;
        uint256 iterations;
        uint256 cursor = poolCursor;
        while (processed < maxPoolsProcessedPerSwap && iterations < pools.length) {
            PoolConfig memory pool = pools[cursor];
            cursor = (cursor + 1) % pools.length;
            iterations++;
            if (!pool.enabled) {
                continue;
            }
            uint256 poolShare = (amount * pool.weightBps) / BPS_DENOM;
            if (poolShare == 0) {
                processed++;
                continue;
            }
            bool success = _swapAndAddLiquidity(pool, poolShare);
            if (success) {
                used += poolShare;
            }
            processed++;
        }
        poolCursor = cursor;
    }

    function _swapAndAddLiquidity(PoolConfig memory pool, uint256 tokenAmount) internal returns (bool) {
        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;
        if (half == 0 || otherHalf == 0) {
            return false;
        }
        if (!_swapTokensForBacking(pool.router, pool.backingToken, half)) {
            return false;
        }
        uint256 backingBalance = IERC20(pool.backingToken).balanceOf(address(this));
        if (backingBalance == 0) {
            return false;
        }
        return _addLiquidity(pool.router, pool.backingToken, otherHalf, backingBalance);
    }

    function _swapTokensForBacking(address router, address backingToken, uint256 amount) internal returns (bool) {
        if (amount == 0) {
            return false;
        }
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = backingToken;
        uint256 amountOutMin = _quoteAmountOutMin(router, amount, path);
        if (amountOutMin == 0) {
            return false;
        }
        _approve(address(this), router, amount);
        try IUniswapV2Router02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount, amountOutMin, path, address(this), block.timestamp
            ) {
            return true;
        } catch {
            return false;
        }
    }

    function _addLiquidity(address router, address backingToken, uint256 tokenAmount, uint256 backingAmount)
        internal
        returns (bool)
    {
        _approve(address(this), router, tokenAmount);
        IERC20(backingToken).approve(router, backingAmount);
        try IUniswapV2Router02(router)
            .addLiquidity(
                address(this),
                backingToken,
                tokenAmount,
                backingAmount,
                (tokenAmount * (BPS_DENOM - slippageBps)) / BPS_DENOM,
                (backingAmount * (BPS_DENOM - slippageBps)) / BPS_DENOM,
                owner,
                block.timestamp
            ) returns (
            uint256, uint256, uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _processBuybackSwap(uint256 tokenAmount) internal returns (uint256 used) {
        if (tokenAmount == 0 || buybackAnkrBnb == address(0) || buybackRouter == address(0)) {
            return 0;
        }
        if (!_swapTokensForBacking(buybackRouter, buybackAnkrBnb, tokenAmount)) {
            return 0;
        }
        used = tokenAmount;
        _executeBuyback();
    }

    function _executeBuyback() internal {
        if (buybackAnkrBnb == address(0) || buybackRouter == address(0)) {
            return;
        }
        if (block.timestamp < lastBuybackTimestamp + buybackCooldownSeconds) {
            return;
        }
        uint256 ankrBnbBalance = IERC20(buybackAnkrBnb).balanceOf(address(this));
        if (ankrBnbBalance == 0) {
            return;
        }
        if (buybackUpperLimitAnkrBnb > 0 && ankrBnbBalance > buybackUpperLimitAnkrBnb) {
            ankrBnbBalance = buybackUpperLimitAnkrBnb;
        }
        if (maxBuybackAnkrBnb > 0 && ankrBnbBalance > maxBuybackAnkrBnb) {
            ankrBnbBalance = maxBuybackAnkrBnb;
        }
        if (ankrBnbBalance == 0) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = buybackAnkrBnb;
        path[1] = address(this);
        uint256 amountOutMin = _quoteAmountOutMin(buybackRouter, ankrBnbBalance, path);
        if (amountOutMin == 0) {
            return;
        }
        IERC20(buybackAnkrBnb).approve(buybackRouter, ankrBnbBalance);
        try IUniswapV2Router02(buybackRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                ankrBnbBalance, amountOutMin, path, DEAD, block.timestamp
            ) {
            lastBuybackTimestamp = block.timestamp;
            emit Buyback(buybackRouter, ankrBnbBalance);
        } catch {
            return;
        }
    }

    function _quoteAmountOutMin(address router, uint256 amount, address[] memory path) internal view returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 quoted;
        try IUniswapV2Router02(router).getAmountsOut(amount, path) returns (uint256[] memory amounts) {
            if (amounts.length < 2) {
                return 0;
            }
            quoted = amounts[amounts.length - 1];
        } catch {
            return 0;
        }
        if (quoted == 0) {
            return 0;
        }
        uint256 minOut = (quoted * (BPS_DENOM - slippageBps)) / BPS_DENOM;
        if (minOut == 0) {
            minOut = 1;
        }
        return minOut;
    }

    function _enforceFeeCap(uint16 reflectionFee, uint16 liquidityFee, uint16 buybackFee) internal pure {
        uint256 total = uint256(reflectionFee) + uint256(liquidityFee) + uint256(buybackFee);
        require(total <= MAX_TOTAL_FEE_BPS, "Fee cap");
    }
}
