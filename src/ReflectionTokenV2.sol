// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IUniswapV2FactoryMinimal {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2PairMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniswapV2RouterMinimal {
    function factory() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

error NotOwner();
error ZeroAddress();
error ZeroOwner();
error AllowanceExceeded();
error ReflectionAmountExceedsTotal();
error ConfigFinalizedError();
error RouterNotContract();
error FactoryNotAllowed();
error RouterNotAllowed();
error PairNotContract();
error PairMissingToken();
error PairNotInFactory();
error BadPathLength();
error BadPathStart();
error BadPathEnd();
error ZeroAddressInPath();
error HopTokenNotAllowed();
error SwapThresholdZero();
error MaxSwapZero();
error SwapThresholdTooHigh();
error MaxSwapTooHigh();
error MaxSwapBelowThreshold();
error SlippageTooHigh();
error CooldownTooHigh();
error MaxBuybackTooHigh();
error UpperLimitTooHigh();
error UpperLimitBelowMax();
error ImpactTooHigh();
error SwapNotFinalized();
error SwapAlreadyEnabled();
error SwapEnabled();
error Reentrancy();
error FeeCapExceeded();
error NotKeeper();
error RecoverNotAllowed();
error InvalidConfig();
error PairRouterNotSet();

library SafeERC20 {
    error SafeERC20Failed();

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        if (_callOptionalReturnBool(token, abi.encodeWithSelector(token.approve.selector, spender, value))) {
            return;
        }
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = address(token).call(data);
        if (!success) {
            return false;
        }
        if (returndata.length == 0) {
            return true;
        }
        return abi.decode(returndata, (bool));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        if (!success) {
            revert SafeERC20Failed();
        }
        if (returndata.length > 0) {
            if (!abi.decode(returndata, (bool))) {
                revert SafeERC20Failed();
            }
        }
    }
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}

contract ReflectionTokenV2 is IERC20, Ownable {
    using SafeERC20 for IERC20;

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

    uint16 public constant reflectionFeeBps = 20;
    uint16 public constant liquidityFeeBps = 40;
    uint16 public constant buybackFeeBps = 40;
    uint16 public constant MAX_TOTAL_FEE_BPS = 100;

    address public immutable ANKRBNB;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    mapping(address => bool) public ammPairs;
    mapping(address => bool) public routerAllowed;
    mapping(address => bool) public factoryAllowed;
    mapping(address => address) public pairRouter;
    mapping(address => bool) public isFeeExempt;
    address[] public ammPairList;
    mapping(address => bool) private _ammPairListed;

    mapping(address => bool) public hopTokenAllowed;
    mapping(bytes32 => address[]) private _path;

    bool public swapEnabled;
    uint256 public swapThreshold;
    uint256 public maxSwapAmount;
    uint16 public slippageBps = 100;
    uint16 public maxBuybackPriceImpactBps = 200;

    uint256 public tokensForLiquidity;
    uint256 public tokensForBuyback;

    bool private _inSwap;

    uint256 public buybackCooldownSeconds;
    uint256 public maxBuybackAnkr;
    uint256 public buybackUpperLimitAnkr;
    uint256 public lastBuybackTimestamp;
    bool public configFinalized;
    address public buybackRouter;
    address public buybackKeeper;
    bool public recoverAnkrEnabled;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    uint256 public constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 public constant DEFAULT_SWAP_THRESHOLD = 100e18;
    uint256 public constant DEFAULT_MAX_SWAP_AMOUNT = 500e18;
    uint256 public constant DEFAULT_MAX_BUYBACK_ANKR = 1e18;
    uint256 public constant DEFAULT_BUYBACK_UPPER_LIMIT_ANKR = 2e18;
    uint256 public constant DEFAULT_BUYBACK_COOLDOWN = 120;
    uint256 public constant MAX_SWAP_THRESHOLD_BPS = 50;
    uint256 public constant MAX_SWAP_AMOUNT_BPS = 100;
    uint256 public constant MAX_BUYBACK_COOLDOWN = 1 days;
    uint256 public constant MAX_BUYBACK_ANKR = 100e18;
    uint16 public constant MAX_BUYBACK_PRICE_IMPACT_BPS = 500;

    bytes32 private constant BUYBACK_FAIL_COOLDOWN = keccak256("COOLDOWN");
    bytes32 private constant BUYBACK_FAIL_DISABLED = keccak256("DISABLED");
    bytes32 private constant BUYBACK_FAIL_AMOUNT_ZERO = keccak256("AMOUNT_ZERO");
    bytes32 private constant BUYBACK_FAIL_AMOUNT_TOO_HIGH = keccak256("AMOUNT_TOO_HIGH");
    bytes32 private constant BUYBACK_FAIL_PAIR_NOT_SET = keccak256("PAIR_NOT_SET");
    bytes32 private constant BUYBACK_FAIL_IMPACT_TOO_HIGH = keccak256("IMPACT_TOO_HIGH");
    bytes32 private constant BUYBACK_FAIL_QUOTE_FAIL = keccak256("QUOTE_FAIL");
    bytes32 private constant BUYBACK_FAIL_SWAP_FAIL = keccak256("SWAP_FAIL");
    bytes32 private constant BUYBACK_FAIL_DEADLINE = keccak256("DEADLINE");

    bytes32 private constant SWAP_BACK_SWAP = keccak256("SWAP_TOKENS_FOR_ANKR");
    bytes32 private constant SWAP_BACK_ADD_LIQUIDITY = keccak256("ADD_LIQUIDITY");

    event SwapBack(uint256 tokensSwapped);
    event SwapBackFailed(bytes32 step, uint256 tokenAmount, uint256 ankrAmount);
    event Buyback(address indexed router, uint256 amountIn);
    event BuybackFailed(bytes32 reason, uint256 amountIn, uint256 minOut, uint256 extra);
    event BuybackOverrideUsed(address indexed router, uint256 amountIn);
    event ConfigFinalized();
    event ConfigUpdated(bytes32 indexed key, address indexed target, uint256 value, bool flag);
    event SwapEnabledUpdated(bool enabled);
    event AmmPairUpdated(address indexed pair, address indexed router, bool isPair);
    event RecoveredERC20(address indexed token, address indexed to, uint256 amount);

    constructor(address ankrBnb_) {
        if (ankrBnb_ == address(0)) {
            revert ZeroAddress();
        }
        name = "Basalt";
        symbol = "BASLT";
        _tTotal = TOTAL_SUPPLY;
        _rTotal = MAX - (MAX % _tTotal);
        ANKRBNB = ankrBnb_;

        _rOwned[msg.sender] = _rTotal;
        emit Transfer(address(0), msg.sender, _tTotal);
        isFeeExempt[address(this)] = true;
        isFeeExempt[msg.sender] = true;
        isFeeExempt[DEAD] = true;
        buybackKeeper = msg.sender;

        _status = _NOT_ENTERED;
        swapEnabled = false;
        swapThreshold = DEFAULT_SWAP_THRESHOLD;
        maxSwapAmount = DEFAULT_MAX_SWAP_AMOUNT;
        buybackCooldownSeconds = DEFAULT_BUYBACK_COOLDOWN;
        maxBuybackAnkr = DEFAULT_MAX_BUYBACK_ANKR;
        buybackUpperLimitAnkr = DEFAULT_BUYBACK_UPPER_LIMIT_ANKR;
        hopTokenAllowed[ANKRBNB] = true;
        hopTokenAllowed[WBNB] = true;
        hopTokenAllowed[BUSD] = true;
        hopTokenAllowed[USDT] = true;
        hopTokenAllowed[USDC] = true;
        _enforceFeeCap();
        _enforceSwapLimits(swapThreshold, maxSwapAmount);
        _enforceBuybackLimits(buybackCooldownSeconds, maxBuybackAnkr, buybackUpperLimitAnkr);
    }

    modifier onlyConfigurable() {
        if (configFinalized) {
            revert ConfigFinalizedError();
        }
        _;
    }

    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert Reentrancy();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner && msg.sender != buybackKeeper) {
            revert NotKeeper();
        }
        _;
    }

    modifier swapsDisabled() {
        if (swapEnabled) {
            revert SwapEnabled();
        }
        _;
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
        if (currentAllowance < amount) {
            revert AllowanceExceeded();
        }
        _approve(sender, msg.sender, currentAllowance - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        if (rAmount > _rTotal) {
            revert ReflectionAmountExceedsTotal();
        }
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    function getRate() external view returns (uint256) {
        return _getRate();
    }

    function validateConfig() external view returns (bool) {
        return _validateConfig();
    }

    function finalizeConfig() external onlyOwner onlyConfigurable {
        if (!_validateConfig()) {
            revert InvalidConfig();
        }
        configFinalized = true;
        emit ConfigFinalized();
    }

    function setFactoryAllowed(address factory, bool allowed) external onlyOwner swapsDisabled {
        factoryAllowed[factory] = allowed;
        emit ConfigUpdated(keccak256("FACTORY_ALLOWED"), factory, 0, allowed);
    }

    function setRouterAllowed(address router, bool allowed) external onlyOwner swapsDisabled {
        if (allowed) {
            if (router.code.length == 0) {
                revert RouterNotContract();
            }
            if (!factoryAllowed[IUniswapV2RouterMinimal(router).factory()]) {
                revert FactoryNotAllowed();
            }
        }
        routerAllowed[router] = allowed;
        emit ConfigUpdated(keccak256("ROUTER_ALLOWED"), router, 0, allowed);
    }

    function setPairRouter(address pair, address router) external onlyOwner swapsDisabled {
        if (pair.code.length == 0) {
            revert PairNotContract();
        }
        if (router == address(0)) {
            revert ZeroAddress();
        }
        if (!routerAllowed[router]) {
            revert RouterNotAllowed();
        }
        address factory;
        try IUniswapV2PairMinimal(pair).factory() returns (address factoryAddress) {
            factory = factoryAddress;
        } catch {
            factory = address(0);
        }
        if (factory != address(0) && !factoryAllowed[factory]) {
            revert FactoryNotAllowed();
        }
        pairRouter[pair] = router;
        emit ConfigUpdated(keccak256("PAIR_ROUTER"), pair, uint256(uint160(router)), true);
    }

    function setAmmPair(address pair, bool allowed) external onlyOwner swapsDisabled {
        if (allowed) {
            if (pair.code.length == 0) {
                revert PairNotContract();
            }
            address token0 = IUniswapV2PairMinimal(pair).token0();
            address token1 = IUniswapV2PairMinimal(pair).token1();
            if (token0 != address(this) && token1 != address(this)) {
                revert PairMissingToken();
            }
            address factory = IUniswapV2PairMinimal(pair).factory();
            if (!factoryAllowed[factory]) {
                revert FactoryNotAllowed();
            }
            if (IUniswapV2FactoryMinimal(factory).getPair(token0, token1) != pair) {
                revert PairNotInFactory();
            }
            address router = pairRouter[pair];
            if (router == address(0)) {
                revert PairRouterNotSet();
            }
            if (!routerAllowed[router]) {
                revert RouterNotAllowed();
            }
        }

        ammPairs[pair] = allowed;
        if (allowed) {
            if (!_ammPairListed[pair]) {
                _ammPairListed[pair] = true;
                ammPairList.push(pair);
            }
        }
        emit ConfigUpdated(keccak256("AMM_PAIR"), pair, uint256(uint160(pairRouter[pair])), allowed);
        emit AmmPairUpdated(pair, pairRouter[pair], allowed);
    }

    function setHopTokenAllowed(address token, bool allowed) external onlyOwner swapsDisabled {
        hopTokenAllowed[token] = allowed;
        emit ConfigUpdated(keccak256("HOP_TOKEN_ALLOWED"), token, 0, allowed);
    }

    function setPath(address router, address tokenIn, address tokenOut, address[] calldata path)
        external
        onlyOwner
        swapsDisabled
    {
        if (!routerAllowed[router]) {
            revert RouterNotAllowed();
        }
        if (path.length < 2 || path.length > 4) {
            revert BadPathLength();
        }
        if (path[0] != tokenIn) {
            revert BadPathStart();
        }
        if (path[path.length - 1] != tokenOut) {
            revert BadPathEnd();
        }
        if (tokenIn == address(this) && tokenOut != ANKRBNB) {
            revert BadPathEnd();
        }
        if (tokenOut == address(this) && tokenIn != ANKRBNB) {
            revert BadPathStart();
        }
        for (uint256 i = 0; i < path.length; i++) {
            address hop = path[i];
            if (hop == address(0)) {
                revert ZeroAddressInPath();
            }
            if (hop == address(this) || hop == tokenIn || hop == tokenOut) {
                continue;
            }
            if (!hopTokenAllowed[hop]) {
                revert HopTokenNotAllowed();
            }
        }
        bytes32 key = _pathKey(router, tokenIn, tokenOut);
        delete _path[key];
        for (uint256 i = 0; i < path.length; i++) {
            _path[key].push(path[i]);
        }
        emit ConfigUpdated(key, router, path.length, true);
    }

    function setSwapSettings(uint256 threshold, uint256 maxSwap) external onlyOwner onlyConfigurable {
        _enforceSwapLimits(threshold, maxSwap);
        swapThreshold = threshold;
        maxSwapAmount = maxSwap;
        emit ConfigUpdated(keccak256("SWAP_SETTINGS"), address(0), threshold, true);
        emit ConfigUpdated(keccak256("SWAP_SETTINGS_MAX"), address(0), maxSwap, true);
    }

    function setSlippageBps(uint16 newSlippage) external onlyOwner onlyConfigurable {
        if (newSlippage > 1000) {
            revert SlippageTooHigh();
        }
        slippageBps = newSlippage;
        emit ConfigUpdated(keccak256("SLIPPAGE_BPS"), address(0), newSlippage, true);
    }

    function setBuybackSettings(uint256 cooldownSeconds, uint256 maxPerCall, uint256 upperLimit)
        external
        onlyOwner
        onlyConfigurable
    {
        _enforceBuybackLimits(cooldownSeconds, maxPerCall, upperLimit);
        buybackCooldownSeconds = cooldownSeconds;
        maxBuybackAnkr = maxPerCall;
        buybackUpperLimitAnkr = upperLimit;
        emit ConfigUpdated(keccak256("BUYBACK_COOLDOWN"), address(0), cooldownSeconds, true);
        emit ConfigUpdated(keccak256("BUYBACK_MAX"), address(0), maxPerCall, true);
        emit ConfigUpdated(keccak256("BUYBACK_UPPER"), address(0), upperLimit, true);
    }

    function setMaxBuybackPriceImpactBps(uint16 newImpactBps) external onlyOwner onlyConfigurable {
        if (newImpactBps > MAX_BUYBACK_PRICE_IMPACT_BPS) {
            revert ImpactTooHigh();
        }
        maxBuybackPriceImpactBps = newImpactBps;
        emit ConfigUpdated(keccak256("BUYBACK_IMPACT_BPS"), address(0), newImpactBps, true);
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        if (enabled) {
            if (!configFinalized) {
                revert SwapNotFinalized();
            }
            if (!_validateConfig()) {
                revert InvalidConfig();
            }
            if (swapEnabled) {
                revert SwapAlreadyEnabled();
            }
            swapEnabled = true;
        } else {
            swapEnabled = false;
        }
        emit ConfigUpdated(keccak256("SWAP_ENABLED"), address(0), 0, enabled);
        emit SwapEnabledUpdated(enabled);
    }

    function setBuybackRouter(address router) external onlyOwner swapsDisabled {
        if (!routerAllowed[router]) {
            revert RouterNotAllowed();
        }
        buybackRouter = router;
        emit ConfigUpdated(keccak256("BUYBACK_ROUTER"), router, 0, true);
    }

    function setBuybackKeeper(address keeper) external onlyOwner {
        if (keeper == address(0)) {
            revert ZeroAddress();
        }
        buybackKeeper = keeper;
        emit ConfigUpdated(keccak256("BUYBACK_KEEPER"), keeper, 0, true);
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (configFinalized && exempt) {
            revert ConfigFinalizedError();
        }
        isFeeExempt[account] = exempt;
        emit ConfigUpdated(keccak256("FEE_EXEMPT"), account, 0, exempt);
    }

    function setRecoverAnkrEnabled(bool enabled) external onlyOwner {
        if (!configFinalized) {
            revert ConfigFinalizedError();
        }
        recoverAnkrEnabled = enabled;
        emit ConfigUpdated(keccak256("RECOVER_ANKR"), address(0), 0, enabled);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) {
            revert ZeroAddress();
        }
        if (token == address(this)) {
            revert RecoverNotAllowed();
        }
        if (token == ANKRBNB) {
            if (!recoverAnkrEnabled || amount > maxBuybackAnkr) {
                revert RecoverNotAllowed();
            }
        }
        IERC20(token).safeTransfer(to, amount);
        emit RecoveredERC20(token, to, amount);
    }

    function _validateConfig() internal view returns (bool) {
        if (ANKRBNB == address(0)) {
            return false;
        }
        if (buybackRouter == address(0) || !routerAllowed[buybackRouter]) {
            return false;
        }
        if (!_hasValidStoredPath(buybackRouter, ANKRBNB, address(this))) {
            return false;
        }
        bool hasActivePair;
        for (uint256 i = 0; i < ammPairList.length; i++) {
            address pair = ammPairList[i];
            if (!ammPairs[pair]) {
                continue;
            }
            hasActivePair = true;
            address router = pairRouter[pair];
            if (router == address(0) || !routerAllowed[router]) {
                return false;
            }
            if (!_hasValidStoredPath(router, address(this), ANKRBNB)) {
                return false;
            }
            address factory;
            try IUniswapV2PairMinimal(pair).factory() returns (address factoryAddress) {
                factory = factoryAddress;
            } catch {
                factory = address(0);
            }
            if (factory != address(0) && !factoryAllowed[factory]) {
                return false;
            }
        }
        if (!hasActivePair) {
            return false;
        }
        return true;
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        if (owner_ == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            emit Transfer(from, to, 0);
            return;
        }

        bool takeFee =
            !_inSwap && !isFeeExempt[from] && !isFeeExempt[to] && (ammPairs[from] || ammPairs[to]) && to != DEAD;

        if (takeFee) {
            _tokenTransferWithFee(from, to, amount);
        } else {
            _tokenTransferNoFee(from, to, amount);
        }

        bool isSell = ammPairs[to];
        if (isSell && swapEnabled && configFinalized && !_inSwap) {
            uint256 contractTokenBalance = balanceOf(address(this));
            if (contractTokenBalance >= swapThreshold) {
                _swapBack(pairRouter[to]);
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
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        if (rSupply == 0 || tSupply == 0 || rSupply < tSupply) {
            return 1;
        }
        return rSupply / tSupply;
    }

    function _syncFeeTokensToBuckets() internal {
        uint256 contractBal = balanceOf(address(this));
        uint256 bucketSum = tokensForLiquidity + tokensForBuyback;
        if (contractBal <= bucketSum) {
            return;
        }
        uint256 excess = contractBal - bucketSum;
        if (bucketSum == 0) {
            tokensForBuyback += excess;
            return;
        }
        uint256 addL = (excess * tokensForLiquidity) / bucketSum;
        uint256 addB = excess - addL;
        tokensForLiquidity += addL;
        tokensForBuyback += addB;
    }

    function _swapBack(address router) internal {
        if (_inSwap) {
            return;
        }
        if (!swapEnabled || !configFinalized) {
            return;
        }
        if (router == address(0) || !routerAllowed[router]) {
            return;
        }
        _syncFeeTokensToBuckets();
        uint256 totalTokensToSwap = tokensForLiquidity + tokensForBuyback;
        if (totalTokensToSwap == 0) {
            return;
        }
        uint256 contractTokenBalance = balanceOf(address(this));
        if (contractTokenBalance < swapThreshold) {
            return;
        }
        uint256 swapAmount = contractTokenBalance;
        if (maxSwapAmount > 0 && swapAmount > maxSwapAmount) {
            swapAmount = maxSwapAmount;
        }
        if (swapAmount > totalTokensToSwap) {
            swapAmount = totalTokensToSwap;
        }
        if (swapAmount == 0) {
            return;
        }

        _inSwap = true;
        uint256 remaining = swapAmount;

        if (tokensForLiquidity > 0 && remaining > 0) {
            uint256 liquidityTarget = tokensForLiquidity;
            if (liquidityTarget > remaining) {
                liquidityTarget = remaining;
            }
            uint256 spent = _processLiquidity(router, liquidityTarget);
            if (spent > 0) {
                if (spent > tokensForLiquidity) {
                    spent = tokensForLiquidity;
                }
                if (spent > remaining) {
                    spent = remaining;
                }
                tokensForLiquidity -= spent;
                remaining -= spent;
            }
        }

        if (tokensForBuyback > 0 && remaining > 0) {
            uint256 buybackTarget = tokensForBuyback;
            if (buybackTarget > remaining) {
                buybackTarget = remaining;
            }
            uint256 spent = _processBuybackSwap(router, buybackTarget);
            if (spent > 0) {
                if (spent > tokensForBuyback) {
                    spent = tokensForBuyback;
                }
                if (spent > remaining) {
                    spent = remaining;
                }
                tokensForBuyback -= spent;
                remaining -= spent;
            }
        }

        _inSwap = false;

        emit SwapBack(swapAmount);
    }

    function _processLiquidity(address router, uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 half = amount / 2;
        uint256 otherHalf = amount - half;
        if (half == 0 || otherHalf == 0) {
            return 0;
        }
        uint256 beforeBalance = IERC20(ANKRBNB).balanceOf(address(this));
        if (!_swapTokensForAnkr(router, otherHalf)) {
            return 0;
        }
        uint256 afterBalance = IERC20(ANKRBNB).balanceOf(address(this));
        uint256 ankrOut = afterBalance - beforeBalance;
        if (ankrOut == 0) {
            return otherHalf;
        }
        bool added = _addLiquidity(router, half, ankrOut);
        if (added) {
            return amount;
        }
        return otherHalf;
    }

    function _swapTokensForAnkr(address router, uint256 amount) internal returns (bool) {
        if (amount == 0) {
            return false;
        }
        address[] memory path = _getPath(router, address(this), ANKRBNB);
        uint256 amountOutMin = _quoteAmountOutMin(router, amount, path);
        if (amountOutMin == 0) {
            emit SwapBackFailed(SWAP_BACK_SWAP, amount, 0);
            return false;
        }
        IERC20(address(this)).forceApprove(router, amount);
        try IUniswapV2RouterMinimal(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount, amountOutMin, path, address(this), block.timestamp
            ) {
            return true;
        } catch {
            emit SwapBackFailed(SWAP_BACK_SWAP, amount, amountOutMin);
            return false;
        }
    }

    function _addLiquidity(address router, uint256 tokenAmount, uint256 ankrAmount) internal returns (bool) {
        IERC20(address(this)).forceApprove(router, tokenAmount);
        IERC20(ANKRBNB).forceApprove(router, ankrAmount);
        uint256 minToken = (tokenAmount * (BPS_DENOM - slippageBps)) / BPS_DENOM;
        uint256 minAnkr = (ankrAmount * (BPS_DENOM - slippageBps)) / BPS_DENOM;
        try IUniswapV2RouterMinimal(router)
            .addLiquidity(
                address(this), ANKRBNB, tokenAmount, ankrAmount, minToken, minAnkr, DEAD, block.timestamp
            ) returns (
            uint256, uint256, uint256
        ) {
            return true;
        } catch {
            emit SwapBackFailed(SWAP_BACK_ADD_LIQUIDITY, tokenAmount, ankrAmount);
            return false;
        }
    }

    function _processBuybackSwap(address router, uint256 tokenAmount) internal returns (uint256) {
        if (tokenAmount == 0) {
            return 0;
        }
        if (!_swapTokensForAnkr(router, tokenAmount)) {
            return 0;
        }
        return tokenAmount;
    }

    function buyback(uint256 ankrAmountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        onlyKeeperOrOwner
        returns (bool)
    {
        if (!swapEnabled || !configFinalized) {
            return _emitBuybackFailed(BUYBACK_FAIL_DISABLED, 0, minOut, 0);
        }
        if (deadline < block.timestamp) {
            return _emitBuybackFailed(BUYBACK_FAIL_DEADLINE, 0, minOut, deadline);
        }
        if (block.timestamp < lastBuybackTimestamp + buybackCooldownSeconds) {
            return _emitBuybackFailed(BUYBACK_FAIL_COOLDOWN, 0, minOut, lastBuybackTimestamp);
        }
        address router = buybackRouter;
        if (router == address(0) || !routerAllowed[router]) {
            return _emitBuybackFailed(BUYBACK_FAIL_DISABLED, 0, minOut, 0);
        }
        uint256 ankrBalance = IERC20(ANKRBNB).balanceOf(address(this));
        if (ankrBalance == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_ZERO, 0, minOut, 0);
        }
        uint256 amountIn = ankrAmountIn == 0 ? ankrBalance : ankrAmountIn;
        if (amountIn > ankrBalance) {
            amountIn = ankrBalance;
        }
        if (buybackUpperLimitAnkr > 0 && amountIn > buybackUpperLimitAnkr) {
            amountIn = buybackUpperLimitAnkr;
        }
        if (maxBuybackAnkr > 0 && amountIn > maxBuybackAnkr) {
            amountIn = maxBuybackAnkr;
        }
        if (amountIn == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_ZERO, 0, minOut, 0);
        }
        address factory;
        try IUniswapV2RouterMinimal(router).factory() returns (address factoryAddress) {
            factory = factoryAddress;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        address pair;
        try IUniswapV2FactoryMinimal(factory).getPair(ANKRBNB, address(this)) returns (address pairAddress) {
            pair = pairAddress;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        if (pair == address(0) || pair.code.length == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        uint256 impactBps = _estimatePriceImpactBps(pair, ANKRBNB, amountIn);
        if (impactBps > maxBuybackPriceImpactBps) {
            return _emitBuybackFailed(BUYBACK_FAIL_IMPACT_TOO_HIGH, amountIn, minOut, impactBps);
        }
        address[] memory path = _getPath(router, ANKRBNB, address(this));
        uint256 amountOutMin = _quoteAmountOutMin(router, amountIn, path);
        if (amountOutMin == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_QUOTE_FAIL, amountIn, minOut, 0);
        }
        if (minOut > amountOutMin) {
            amountOutMin = minOut;
        }
        IERC20(ANKRBNB).forceApprove(router, amountIn);
        try IUniswapV2RouterMinimal(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, DEAD, deadline) {
            lastBuybackTimestamp = block.timestamp;
            emit Buyback(router, amountIn);
            return true;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_SWAP_FAIL, amountIn, amountOutMin, 0);
        }
    }

    function buybackOverride(uint256 amountIn, uint256 minOut) external nonReentrant onlyOwner returns (bool) {
        if (!swapEnabled || !configFinalized) {
            return _emitBuybackFailed(BUYBACK_FAIL_DISABLED, amountIn, minOut, 0);
        }
        if (block.timestamp < lastBuybackTimestamp + buybackCooldownSeconds) {
            return _emitBuybackFailed(BUYBACK_FAIL_COOLDOWN, amountIn, minOut, lastBuybackTimestamp);
        }
        if (amountIn == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_ZERO, amountIn, minOut, 0);
        }
        if (maxBuybackAnkr > 0 && amountIn > maxBuybackAnkr) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_TOO_HIGH, amountIn, minOut, maxBuybackAnkr);
        }
        if (buybackUpperLimitAnkr > 0 && amountIn > buybackUpperLimitAnkr) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_TOO_HIGH, amountIn, minOut, buybackUpperLimitAnkr);
        }
        address router = buybackRouter;
        if (router == address(0) || !routerAllowed[router]) {
            return _emitBuybackFailed(BUYBACK_FAIL_DISABLED, amountIn, minOut, 0);
        }
        uint256 ankrBalance = IERC20(ANKRBNB).balanceOf(address(this));
        if (ankrBalance < amountIn) {
            return _emitBuybackFailed(BUYBACK_FAIL_AMOUNT_TOO_HIGH, amountIn, minOut, ankrBalance);
        }
        address factory;
        try IUniswapV2RouterMinimal(router).factory() returns (address factoryAddress) {
            factory = factoryAddress;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        address pair;
        try IUniswapV2FactoryMinimal(factory).getPair(ANKRBNB, address(this)) returns (address pairAddress) {
            pair = pairAddress;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        if (pair == address(0) || pair.code.length == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_PAIR_NOT_SET, amountIn, minOut, 0);
        }
        address[] memory path = _getPath(router, ANKRBNB, address(this));
        uint256 amountOutMin = _quoteAmountOutMin(router, amountIn, path);
        if (amountOutMin == 0) {
            return _emitBuybackFailed(BUYBACK_FAIL_QUOTE_FAIL, amountIn, minOut, 0);
        }
        if (minOut > amountOutMin) {
            amountOutMin = minOut;
        }
        IERC20(ANKRBNB).forceApprove(router, amountIn);
        try IUniswapV2RouterMinimal(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, amountOutMin, path, DEAD, block.timestamp
            ) {
            lastBuybackTimestamp = block.timestamp;
            emit Buyback(router, amountIn);
            emit BuybackOverrideUsed(router, amountIn);
            return true;
        } catch {
            return _emitBuybackFailed(BUYBACK_FAIL_SWAP_FAIL, amountIn, amountOutMin, 0);
        }
    }

    function _estimatePriceImpactBps(address pair, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        if (amountIn == 0) {
            return 0;
        }
        address token0;
        address token1;
        try IUniswapV2PairMinimal(pair).token0() returns (address token0Address) {
            token0 = token0Address;
        } catch {
            return BPS_DENOM;
        }
        try IUniswapV2PairMinimal(pair).token1() returns (address token1Address) {
            token1 = token1Address;
        } catch {
            return BPS_DENOM;
        }
        (uint112 reserve0, uint112 reserve1,) = _safeGetReserves(pair);
        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0) {
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else if (tokenIn == token1) {
            reserveIn = reserve1;
            reserveOut = reserve0;
        } else {
            return BPS_DENOM;
        }
        if (reserveIn == 0 || reserveOut == 0) {
            return BPS_DENOM;
        }
        uint256 spotOut = (amountIn * reserveOut) / reserveIn;
        if (spotOut == 0) {
            return BPS_DENOM;
        }
        uint256 amountInWithFee = amountIn * 997;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        if (amountOut >= spotOut) {
            return 0;
        }
        return ((spotOut - amountOut) * BPS_DENOM) / spotOut;
    }

    function _safeGetReserves(address pair) internal view returns (uint112, uint112, uint32) {
        try IUniswapV2PairMinimal(pair).getReserves() returns (
            uint112 reserve0, uint112 reserve1, uint32 timestampLast
        ) {
            return (reserve0, reserve1, timestampLast);
        } catch {
            return (0, 0, 0);
        }
    }

    function _quoteAmountOutMin(address router, uint256 amount, address[] memory path) internal view returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 quoted;
        try IUniswapV2RouterMinimal(router).getAmountsOut(amount, path) returns (uint256[] memory amounts) {
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

    function _hasValidStoredPath(address router, address tokenIn, address tokenOut) internal view returns (bool) {
        bytes32 key = _pathKey(router, tokenIn, tokenOut);
        address[] storage stored = _path[key];
        if (stored.length < 2) {
            return false;
        }
        if (stored[0] != tokenIn || stored[stored.length - 1] != tokenOut) {
            return false;
        }
        for (uint256 i = 0; i < stored.length; i++) {
            if (stored[i] == address(0)) {
                return false;
            }
        }
        return true;
    }

    function _pathKey(address router, address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encode(router, tokenIn, tokenOut));
    }

    function _getPath(address router, address tokenIn, address tokenOut) internal view returns (address[] memory) {
        bytes32 key = _pathKey(router, tokenIn, tokenOut);
        address[] storage stored = _path[key];
        if (stored.length > 0) {
            address[] memory path = new address[](stored.length);
            for (uint256 i = 0; i < stored.length; i++) {
                path[i] = stored[i];
            }
            return path;
        }
        address[] memory direct = new address[](2);
        direct[0] = tokenIn;
        direct[1] = tokenOut;
        return direct;
    }

    function _getCurrentSupply() internal view returns (uint256 rSupply, uint256 tSupply) {
        rSupply = _rTotal;
        tSupply = _tTotal;
        if (tSupply == 0 || rSupply == 0 || rSupply < tSupply) {
            return (_rTotal, _tTotal);
        }
    }

    function _emitBuybackFailed(bytes32 reason, uint256 amountIn, uint256 minOut, uint256 extra)
        internal
        returns (bool)
    {
        emit BuybackFailed(reason, amountIn, minOut, extra);
        return false;
    }

    function _enforceFeeCap() internal pure {
        uint256 total = uint256(reflectionFeeBps) + uint256(liquidityFeeBps) + uint256(buybackFeeBps);
        if (total > MAX_TOTAL_FEE_BPS) {
            revert FeeCapExceeded();
        }
    }

    function _enforceSwapLimits(uint256 threshold, uint256 maxSwap) internal view {
        if (threshold == 0) {
            revert SwapThresholdZero();
        }
        if (maxSwap == 0) {
            revert MaxSwapZero();
        }
        if (threshold > (_tTotal * MAX_SWAP_THRESHOLD_BPS) / BPS_DENOM) {
            revert SwapThresholdTooHigh();
        }
        if (maxSwap > (_tTotal * MAX_SWAP_AMOUNT_BPS) / BPS_DENOM) {
            revert MaxSwapTooHigh();
        }
        if (maxSwap < threshold) {
            revert MaxSwapBelowThreshold();
        }
    }

    function _enforceBuybackLimits(uint256 cooldownSeconds, uint256 maxPerCall, uint256 upperLimit) internal pure {
        if (cooldownSeconds > MAX_BUYBACK_COOLDOWN) {
            revert CooldownTooHigh();
        }
        if (maxPerCall > 0) {
            if (maxPerCall > MAX_BUYBACK_ANKR) {
                revert MaxBuybackTooHigh();
            }
        }
        if (upperLimit > 0) {
            if (upperLimit > MAX_BUYBACK_ANKR) {
                revert UpperLimitTooHigh();
            }
            if (maxPerCall > 0) {
                if (upperLimit < maxPerCall) {
                    revert UpperLimitBelowMax();
                }
            }
        }
    }
}
