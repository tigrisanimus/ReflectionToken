// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPair {
    address public token0;
    address public token1;
    address public factory;

    constructor(address token0_, address token1_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
    }
}
