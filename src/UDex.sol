// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Oracle} from "./Oracle.sol";
import {AggregatorV3Interface} from "@pluginV2/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibError} from "./lib/LibError.sol";

contract UDex is ERC4626, Ownable, ReentrancyGuard {
    //================================================================================
    // Libraries
    //================================================================================
    using Oracle for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    //================================================================================
    // State Variables
    //================================================================================
    AggregatorV3Interface public immutable i_priceFeed;

    IERC20 public immutable i_xdc;
    uint16 private constant DEAD_SHARES = 1000;

    PositionsSummary totalLongPositions;
    PositionsSummary totalShortPositions;

    mapping(address => Position) positions;
    uint256 public tradersCollateral;
    uint256 private positionFeeBasisPoints;
    uint256 public s_totalLiquidityDeposited;

    //================================================================================
    // Events
    //================================================================================

    event PositionOpened(
        address indexed user, bool isLong, uint256 collateral, uint256 size, uint256 ethAmount, uint256 avgEthPrice
    );

    //================================================================================
    // Custom Structs
    //================================================================================
    struct Position {
        uint256 collateral;
        uint256 avgEthPrice;
        uint256 ethAmount;
        bool isLong;
        uint256 lastChangeTimestamp;
    }

    struct PositionsSummary {
        uint256 sizeInXdc;
        uint256 sizeInEth;
    }

    //================================================================================
    // Constants
    //================================================================================

    uint256 public constant MAX_LEVARAGE = 15;

    constructor(address priceFeed, IERC20 _xdc) ERC4626(_xdc) ERC20("UDex", "UDX") Ownable(msg.sender) {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_xdc = IERC20(_xdc);

        // avoiding inflationary attack
        _mint(address(this), DEAD_SHARES);
    }

    //================================================================================
    // Override ERC4626
    //================================================================================

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited + assets;
        shares = super.deposit(assets, receiver);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited - assets;
        shares = super.withdraw(assets, receiver, owner);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        s_totalLiquidityDeposited += assets;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.redeem(shares, receiver, owner);
        s_totalLiquidityDeposited -= assets;
    }
    //================================================================================
    // Traders functionality
    //================================================================================

    function openPosition(uint256 size, uint256 collateral, bool isLong) public {
        if (collateral <= 0) {
            revert LibError.UDex__ErrorInsufficientCollateral();
        }
        if (size <= 0) {
            revert LibError.UDex__ErrorSize();
        }
        if (positions[msg.sender].collateral != 0) {
            revert LibError.UDex__PositionAlreadyExist();
        }

        uint256 currentETHPrice = getPrice();

        //createPosition
        Position memory position = Position({
            avgEthPrice: currentETHPrice, //review about decimals precision
            collateral: collateral, //same review
            ethAmount: size / currentETHPrice, // review
            isLong: isLong,
            lastChangeTimestamp: block.timestamp
        });
        _checkPositionHealth(position, currentETHPrice);
        i_xdc.safeTransferFrom(msg.sender, address(this), collateral);

        //contract state
        tradersCollateral += position.collateral;
        positions[msg.sender] = position;
        _increasePositionsSumary(size, position.ethAmount, isLong); //review decimals

        emit PositionOpened(msg.sender, position.isLong, size, collateral, position.ethAmount, position.avgEthPrice);
    }

    //================================================================================
    // Oracle Price
    //================================================================================
    function getPrice() public view returns (uint256) {
        return Oracle.getPrice(i_priceFeed);
    }
    //================================================================================
    // Internal functions
    //================================================================================

    function _increasePositionsSumary(uint256 sizeINXDC, uint256 sizeInEth, bool isLong) internal {
        if (isLong) {
            totalLongPositions.sizeInXdc += sizeINXDC;
            totalLongPositions.sizeInEth += sizeInEth;
        } else {
            totalShortPositions.sizeInXdc += sizeINXDC;
            totalShortPositions.sizeInEth += sizeInEth;
        }
    }

    function _checkPositionHealth(Position memory position, uint256 currentEthPrice) internal pure {
        int256 positionPnL = _calculatePositionPnL(position, currentEthPrice);

        if (position.collateral.toInt256() + positionPnL <= 0) {
            revert LibError.UDex__InsufficientPositionCollateral();
        }

        uint256 positionCollateral = (position.collateral.toInt256() + positionPnL).toUint256();

        uint256 levarage = ((position.ethAmount * position.avgEthPrice) / positionCollateral); // review

        if (levarage >= MAX_LEVARAGE) {
            revert LibError.UDex__BreaksHealthFactor();
        }
    }

    function _calculatePositionPnL(Position memory position, uint256 currentEthPrice) internal pure returns (int256) {
        int256 currentPositionValue = (position.ethAmount * currentEthPrice).toInt256();

        int256 positionValueWhenCreated = (position.ethAmount * position.avgEthPrice).toInt256();

        if (position.isLong) {
            return (currentPositionValue - positionValueWhenCreated);
        } else {
            return (positionValueWhenCreated - currentPositionValue);
        }
    } // review all functions about decimals precision
}
