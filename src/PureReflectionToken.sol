// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract PureReflectionToken is IERC20 {
    // Burn destination you can send tokens to.
    // It WILL receive reflections (since we do not exclude anyone).
    address public constant DEAD = address(0xdead);

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant FEE_BPS = 100; // 1%

    uint256 private constant MAX = type(uint256).max;
    uint256 private immutable _tTotal; // token total supply
    uint256 private _rTotal; // reflection total supply

    mapping(address => uint256) private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    error ZeroAddress();
    error AllowanceExceeded();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 totalSupplyTokens,
        address initialHolder
    ) {
        if (initialHolder == address(0)) revert ZeroAddress();

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        _tTotal = totalSupplyTokens;
        _rTotal = MAX - (MAX % _tTotal);

        uint256 tDead = (_tTotal * 90) / 100;
        uint256 tHolder = _tTotal - tDead;

        uint256 rate = _getRate();
        uint256 rDead = tDead * rate;
        uint256 rHolder = _rTotal - rDead;

        _rOwned[DEAD] = rDead;
        _rOwned[initialHolder] = rHolder;

        emit Transfer(address(0), DEAD, tDead);
        emit Transfer(address(0), initialHolder, tHolder);
    }

    function totalSupply() external view returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view returns (uint256) {
        return tokenFromReflection(_rOwned[account]);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allowances[from][msg.sender];
        if (a < amount) revert AllowanceExceeded();
        unchecked {
            _allowances[from][msg.sender] = a - amount;
        }
        emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        _transfer(from, to, amount);
        return true;
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        uint256 rate = _getRate();
        return rate == 0 ? 0 : (rAmount / rate);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address from, address to, uint256 tAmount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (tAmount == 0) {
            emit Transfer(from, to, 0);
            return;
        }

        uint256 rate = _getRate();

        uint256 tFee = (tAmount * FEE_BPS) / BPS_DENOM;
        uint256 tTransfer = tAmount - tFee;

        uint256 rAmount = tAmount * rate;
        uint256 rFee = tFee * rate;
        uint256 rTransfer = rAmount - rFee;

        _rOwned[from] -= rAmount;
        _rOwned[to] += rTransfer;

        // This is the entire “reflection” mechanism:
        // shrinking rTotal makes every rOwned represent more tokens over time.
        _rTotal -= rFee;

        emit Transfer(from, to, tTransfer);
    }

    function _getRate() internal view returns (uint256) {
        return _rTotal / _tTotal;
    }
}
