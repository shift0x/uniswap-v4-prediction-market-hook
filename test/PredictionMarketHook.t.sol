// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";

import { 
    PredictionMarket,
    Position,
    Side 
} from "../src/Types.sol";

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract PredictionMarketHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PredictionMarketHook hook;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);
        

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG 
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        uint24 defaultFee = 500;
        bytes memory constructorArgs = abi.encode(manager, defaultFee); //Add all the necessary constructor arguments from the hook
        deployCodeTo("PredictionMarketHook.sol:PredictionMarketHook", constructorArgs, flags);
        hook = PredictionMarketHook(flags);

        // Approve token spend from the hook contract
        IERC20(Currency.unwrap(currency0)).approve(flags, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(flags, type(uint256).max);

        // Create the pool
        uint24 dynamicFee = 0x800000;

        key = PoolKey(currency0, currency1, dynamicFee, 50, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testAddLiquidityToUnregisteredPool() public {
        vm.expectRevert(PredictionMarketHook.PoolNotFound.selector);

        PoolKey memory unregisteredPoolKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        PoolId unregisteredPoolId = unregisteredPoolKey.toId();

        //passing any non registered poolId should revert. 
        hook.addLiquidity(unregisteredPoolId, block.timestamp+60, 1e18, Side.Both);
    }

    function testAddLiquidityWithCloseTimestampInPast() public {
        vm.expectRevert(PredictionMarketHook.TimestampIsInPast.selector);

        hook.addLiquidity(poolId, block.timestamp, 1e18, Side.Both);
    }

    function testSuccessfulAddLiquidity() public {
        uint8 decimals = 18;
        uint256 amountIn = 1*(10**decimals);
        uint256 endTimestamp = block.timestamp+60;
        bytes32 marketId = hook.getMarketId(poolId, endTimestamp);
        
        Position memory position = hook.addLiquidity(poolId, endTimestamp, amountIn, Side.Both);

        PredictionMarket memory market = hook.getMarketById(marketId);

        uint256 expectedFee = Math.mulDiv(amountIn, hook.FEE(), 1e6);

        // Fetch the sqrtX96Price from the pool manager
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        assertEq(marketId, market.id);
        assertEq(position.bullAmount, amountIn/2);
        assertEq(position.bearAmount, amountIn/2);
        assertEq(amountIn, market.liquidity);
        assertEq(sqrtPriceX96, market.openPrice);
        assertEq(expectedFee, market.fees);
    }
}