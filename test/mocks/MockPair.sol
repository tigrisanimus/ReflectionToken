// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPair {
    address public token0;
    address public token1;
    address public factory;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}
