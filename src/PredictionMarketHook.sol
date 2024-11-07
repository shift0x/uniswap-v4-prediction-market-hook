// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { PredictionMarketLib } from './lib/PredictionMarketLib.sol';
import { PredictionMarketStorage } from './lib/PredictionMarketStorage.sol';
import { PositionStorage } from './lib/PositionStorage.sol';
import { 
    PredictionMarket,
    Position,
    Side,
    PoolInfo 
} from './Types.sol';

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @notice Host prediction markets using balancer pools as price oracles. Fees collected from the markets are distributed to LPs
 * @dev  This hook creates asset price prediction markets on top of balancer pools. Participants are charged
 * fees on entry and when they make modifications to their positions. Fees are donated back to pool (effectively increasing the value
 * of BPT shares for all users).
 *
 * Since the only way to deposit fee tokens back into the pool balance (without minting new BPT) is through
 * the special "donation" add liquidity type, this hook also requires that the pool support donation.
 */
contract PredictionMarketHook is BaseHook {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using PredictionMarketLib for PredictionMarket;
    using PredictionMarketStorage for mapping(bytes32 => PredictionMarket);
    using PositionStorage for mapping(bytes32 => mapping(address => Position));
    using PositionStorage for Position;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice fee charged by hook to prediction market participants
    uint256 public constant FEE = 10000; // 1%

    /// @notice waiting period after a swap occurs in a pool and when a market can be settled
    uint256 public constant SETTLEMENT_WAITING_PERIOD_BLOCKS = 10;

    /// @notice the default transaction fee for swappers not participating in a prediction market
    uint24 public immutable DEFAULT_SWAP_FEE;
    
    /**
     * @notice Mapping between prediction market id and the corresponding markets
     * @dev mapping(marketId => PredictionMarket)
     * marketId = keccak256(abi.encodePacked(poolId, closedAtTimestamp));
     */
    mapping(bytes32 => PredictionMarket) public markets;

    /**
     * @notice Mapping of user positions to corresponding markets
     * @dev mapping(marketId => mapping(userAddress => Position))
     */
    mapping(bytes32 => mapping(address => Position)) public positions;
    
    /**
     * @notice Stored pool information lookup
     * @dev PoolInfo is used to store information like registration status, currency and the last swap block
     * of the pool.
     *
     * Market settlement will fail if the last pool swap was done within the configured SETTLEMENT_WAITING_PERIOD_BLOCKS.
     * This is to mitigate price manipulation possibilities by allowing arbitrage to bring the pool back into balance
     * if it has been brought out of balance by a malicious actor
     */ 
    mapping(PoolId => PoolInfo) private _poolRegistry;

    /**
     * @notice Lookup of user address and pool prediction market participation end time
     * @dev Market participants are incentivized with 0 swap fees. This lookup is used to determine when 
     * if a user is a participant in a market priced by a given pool
     *
     * mapping(userAddress => mapping(pool => marketCloseTimestamp))
     */
    mapping(address => mapping(PoolId => uint256)) private _predictionMarketPartipants;

    /**
     * @notice A new `PredictionMarketHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event PredictionMarketHookRegistered(address indexed hooksContract, PoolId indexed pool);

    /// @notice The pool does not support adding liquidity through donation.
    error PoolDoesNotSupportDonation();

    /// @notice The pool is not registered with the hook
    error PoolNotFound();

    /// @notice Time provided timestamp is in the past
    error TimestampIsInPast();

    /// @notice The pool must use a dynamic fee
    error PoolMustUseDynamicFees();

    /// @notice Unuathorized call
    error Unauthorized();

    /// @dev Only pools with hooks set to this contract may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        uint24 fee) BaseHook(_poolManager
    ) {
        DEFAULT_SWAP_FEE = fee;
    }

    
    /************************************
     * Hook Overrides    
     ************************************/

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(
        address, 
        PoolKey calldata key, 
        uint160
    ) external override returns (bytes4) {
        // Revert if the pool does not support dynamic fee (0x800000). 
        // This is needed to properly incentivize arb in the pool
        if (key.fee != 0x800000){
            revert PoolMustUseDynamicFees();
        } 

        PoolId poolId = key.toId();

        _poolRegistry[poolId] = PoolInfo(key, 0, true);

        emit PredictionMarketHookRegistered(address(this), poolId);

        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata, 
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BeforeSwapDelta, uint24){
        PoolId poolId = key.toId();
        uint24 fee = DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Record the last swap block for the pool. Used later to determine whether a market should
        // be settled.
        _poolRegistry[poolId].lastActivityBlock = block.number;
        
        // if the swapper is participating in an unexpired prediction market, then allow them to swap
        // for 0 fee. This is to incentivize arbitrage that will bring the pool price back into balance
        // to protect the pool price from being manipulated.
        uint256 timestamp = _predictionMarketPartipants[msg.sender][poolId];

        if(timestamp > block.timestamp){
            fee = 0 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /************************************
     * Prediction Market Methods    
     ************************************/ 
     

    /**
     * @notice Get the market id from the given market params
     * @dev Useful for external callers
     *
     * @param pool Pool hosting the prediction market
     * @param closedAtTimestamp Timestamp for when the market closes
     * @return marketId hashed market id
     */
    function getMarketId(
        PoolId pool,
        uint256 closedAtTimestamp
    ) public pure returns (bytes32 marketId) {
        return PredictionMarketStorage.getMarketId(pool, closedAtTimestamp);
    }

    /**
     * @notice Get a market given it's id
     * @param id The market id
     * @return market The resolved prediction market
     */
    function getMarketById(
        bytes32 id
    ) public view returns (PredictionMarket memory) {
        return markets[id];
    }

    /**
     * @notice Add liquidity to a given prediction market
     * @dev The deposit token taken from the user balance will be the token0 of the given market, which is the 
     * first token in the sorted pair
     *
     * User positions will be credited based on the current balance of "bets" between bull/bear outcomes. If the 
     * market is uninitalized then the user will receive equal amounts of bull/bear units, representing a 50/50 
     * probability of each outcome.
     *
     * The total value of a market at any given time is equal of the deposited liquidity. This is the amount that 
     * will be split between the assets when the market is settled. For example, a market with 100 USDC deposited 
     * and a 80/20 balance split between bull / bear would imply a bull price/probability of ($.8) and a bear 
     * price/probability of ($.2). If this ratio continued to settlement then each bull unit would be worth $1.25 
     * while each bear unit is worth $0
     *
     * One can think of this style of prediction market as an implementation of on-chain binary options 
     *
     * @param pool Pool hosting the prediction market
     * @param closedAtTimestamp Timestamp for when the market closes
     * @param amount Deposit amount
     * @param side Side to add liquidity to, optionally choose both to add proportionally
     * @return position Resulting user liquidity position after deposit
     */
    function addLiquidity(
        PoolId pool,
        uint256 closedAtTimestamp,
        uint256 amount,
        Side side
    ) public returns (Position memory position) {
        PoolInfo memory poolInfo = _poolRegistry[pool];

        // only create prediction markets for pools registered with the hook
        if(!poolInfo.registered) {
            revert PoolNotFound();
        }

        // do not addLiquidity or create new markets when the closed timestamp is in the past
        if(closedAtTimestamp <= block.timestamp) {
            revert TimestampIsInPast();
        }
        
        // add liquidity to the corresponding prediction market to the user request. If one is not found, one will be created
        (uint256 bullAmount, uint256 bearAmount, PredictionMarket memory market) = 
            markets.addLiquidity(pool, closedAtTimestamp, poolManager, side, amount, FEE);

        // transfer deposit funds from the user account to the hook contract. The user position will be updated for bull 
        // and bear units corresponding to the current market prices after fees. 
        IERC20(Currency.unwrap(poolInfo.pool.currency0)).safeTransferFrom(msg.sender, address(this), amount);

        // Apply user position deltas and store the updated market. Add liquidity deltas are always positive uint256, so we 
        // need to convert them to int256() prior to calling applyPositionDelta(int256, int256).
        Position memory updatedPosition = positions.applyPositionDelta(market.id, msg.sender, bullAmount.toInt256(), bearAmount.toInt256());

        // record the market particpation for the user and pool combination. This will allow the user to have 0 tx fees when 
        // swapping in the pool to incentivize keeping the pool balanced via arbitrage. The latest timestamp value should be stored.
        uint256 currentTimestamp = _predictionMarketPartipants[msg.sender][pool];

        if(closedAtTimestamp > currentTimestamp){
            _predictionMarketPartipants[msg.sender][pool] = closedAtTimestamp;
        }

        return updatedPosition;
    }

    /**
     * @notice settle the given market
     * @dev after markets are settled, participants can claim their payouts
     *
     * market must be past their end time into order to be claimed
     * @param marketId the market to settle
     * @return market the settled prediction market
     *
     */
    function settle(bytes32 marketId) public returns (PredictionMarket memory market) {
        PoolId pool = markets[marketId].pool;
        PoolInfo memory poolInfo = _poolRegistry[pool];

        PredictionMarket memory settledMarket = markets.settle(
            marketId, 
            poolInfo.lastActivityBlock, 
            SETTLEMENT_WAITING_PERIOD_BLOCKS, 
            poolManager,
            Currency.unwrap(poolInfo.pool.currency0));

        poolManager.donate(poolInfo.pool, settledMarket.fees, 0, new bytes(0));

        return settledMarket;
    }

    /**
     * @notice claim payouts from a settled market
     * @dev the market must be settled in order to claim AND the sender must have a winning final position
     * @param marketId the market to claim winnings from
     * @return winnings the amount claimed to the msg.sender
     */
    function collect(bytes32 marketId) public returns (uint256 winnings){
        // fetch the market and settle it try to settle it if it's still open
        PredictionMarket memory market = markets[marketId];

        if(!market.settled){
            settle(marketId);
        }

        // determine the amount of funds to send to the user if any then mark the position as claimed
        Position memory position = positions[marketId][msg.sender];

        if(position.collected){
            return 0;
        }

        address claimToken = Currency.unwrap(_poolRegistry[market.pool].pool.currency0);
        uint256 userClaimAmount = position.getClaimableBalance(market, claimToken);

        positions[marketId][msg.sender].collected = true;

        if(userClaimAmount > 0){
            IERC20(claimToken).safeTransfer(msg.sender, userClaimAmount);
        }

        return userClaimAmount;
    }

    /**
     * @notice swap a position holdings between sides 
     * @dev bull -> bear or bear -> bull
     *
     * Fees are charged for each swap and maintained on the market for processing during settlement
     * @param marketId Identifier of the market to swap
     * @param from Side to swap from
     * @param amountIn Amount to swap
     * @return position Updated user position after the swap
     */
    function swap(
        bytes32 marketId,
        Side from,
        uint256 amountIn
    ) public returns (Position memory position) {
        // get output amount from the market and prepare amount deltas
        uint256 amountOut = markets.swap(marketId, from, amountIn, FEE);

        int256 amountInDelta = amountIn.toInt256()*-1;
        int256 amountOutdelta = amountOut.toInt256();

        (int256 bullAmountDelta, int256 bearAmountDelta) = from == Side.Bull ? 
            (amountInDelta, amountOutdelta) :
            (amountOutdelta, amountInDelta);

        // update the position with the amount deltas
        Position memory updatedPosition = positions.applyPositionDelta(marketId, msg.sender, bullAmountDelta, bearAmountDelta);

        return updatedPosition;
    }



}