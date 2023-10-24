// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address ethXdcPriceFeed;
        address xdc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_XDC_PRICE = 1000e8;
    uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 50) {
            activeNetworkConfig = getXDCConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getXDCConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            ethXdcPriceFeed: 0xD323e137058522bc2fCab343afF8287e1aD4Deb0,
            xdc: 0x66634c63B756b8701465dD7B3031E668e23E6D4e, //false address
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.ethXdcPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator priceFeed = new MockV3Aggregator(DECIMALS, ETH_XDC_PRICE);
        ERC20Mock xdcMock = new ERC20Mock();
        vm.stopBroadcast();

        return
            NetworkConfig({ethXdcPriceFeed: address(priceFeed), xdc: address(xdcMock), deployerKey: DEFAULT_ANVIL_KEY});
    }
}
