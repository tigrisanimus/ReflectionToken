// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {PureReflectionToken} from "../src/PureReflectionToken.sol";

contract DeployPureReflection is Script {
    function run() external {
        vm.startBroadcast();

        address initialHolder;
        if (vm.envExists("INITIAL_HOLDER")) {
            initialHolder = vm.envAddress("INITIAL_HOLDER");
        } else if (vm.envExists("PRIVATE_KEY")) {
            initialHolder = vm.addr(vm.envUint("PRIVATE_KEY"));
        } else {
            revert("Set INITIAL_HOLDER or PRIVATE_KEY");
        }

        PureReflectionToken token = new PureReflectionToken("Basalt", "BSLT", 18, 1000e18, initialHolder);

        console2.log("PureReflectionToken deployed at:", address(token));
        console2.log("DEAD balance:", token.balanceOf(token.DEAD()));
        console2.log("Initial holder balance:", token.balanceOf(initialHolder));

        if (initialHolder == token.DEAD()) {
            require(token.balanceOf(token.DEAD()) == 1000e18, "DEAD balance mismatch");
        } else {
            require(token.balanceOf(token.DEAD()) == 900e18, "DEAD balance mismatch");
            require(token.balanceOf(initialHolder) == 100e18, "holder balance mismatch");
        }

        vm.stopBroadcast();
    }
}
