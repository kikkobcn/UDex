// SFDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@pluginV2/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {LibError} from "./lib/LibError.sol";

library Oracle {
    uint256 private constant TIMEOUT = 36000;
    uint256 private constant DECIMALS_ADJUSTAMENTS = 1e10; // To adjust the 8 decimal ETH price to 18 decimals

    function getPrice(AggregatorV3Interface priceFeed) public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

        uint256 updateTime = block.timestamp - updatedAt;
        if (updateTime > TIMEOUT) {
            revert LibError.Oracle__ErrorPrice();
        }

        return uint256(answer) * DECIMALS_ADJUSTAMENTS;
    }
}
