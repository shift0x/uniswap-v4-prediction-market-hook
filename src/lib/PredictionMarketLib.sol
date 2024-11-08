// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { 
    PredictionMarket,
    Side 
} from '../Types.sol';

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

library PredictionMarketLib { 
    using StateLibrary for IPoolManager;

    /**
     * @notice Prediction market has zero token balance for one of both pair tokens
     */
    error ZeroTokenBalance();

    /**
     * @notice Prediction market has insufficent liquidity to execute swap
     */
    error CannotSwapInMarket();

    /**
     * @notice Prediction market does not have liquidity on both sides
     * @dev Occurs when a user tries to add liquidity proportionally to a single sided market
     * In this case, the market cannot quote the side with zero liquidity
     */
     error CannotAddProportionalLiquidityToSingleSidedMarket();

    
    /**
     * @notice Quote the current prices (probabilities) of the prediction market
     * @dev The total value of the market is always equal to the deposited liquidity, thus to
     * get the probability or price of each outcome, we need to divide the net outcome balance
     * by the total deposited liquidity.
     * @param self The prediction market to quote
     */
    function quote(
        PredictionMarket memory self
    ) internal pure returns (uint256 quoteBull, uint256 quoteBear) {
        uint256 defaultPrice = 1e18/2;

        if(self.balanceBear * self.balanceBull == 0){
            return (defaultPrice, defaultPrice);
        }

        uint256 units = self.balanceBull + self.balanceBear;

        quoteBull = Math.mulDiv(self.balanceBull, 1e18, units);
        quoteBear = Math.mulDiv(self.balanceBear, 1e18, units);
    }

    /**
     * @notice Quote the asset pair in the underlying pool
     * @param self The prediction market to quote
     * @param poolManager The pool manager to get pool state from
     */
    function quoteUnderlying(
        PredictionMarket memory self,
        IPoolManager poolManager
    ) internal view returns(uint256) {
        // Fetch the sqrtX96Price from the pool manager
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(self.pool);

        return uint256(sqrtPriceX96);
    }

    /**
     * @notice Whether a market has been initalized
     * @dev All initalized markets have at minimum an open price
     * @param self The prediction market
     */
    function isInitalized(PredictionMarket memory self) internal pure returns (bool) {
        return self.openPrice > 0;
    }

    /**
     * @notice Whether a market is currently active 
     * @dev A market is active and can accept swaps / deposits if it is initalized and the
     * end time has not passed
     * @param self The prediction market
     */
    function isActive(PredictionMarket memory self) internal view returns (bool) {
        return isInitalized(self) && self.endTime > block.timestamp;
    }

    /**
     * @notice Calculate the net available liquidity in the market after fees
     * @dev Used to calculate quotes since we keep all liquidity in the market until settlement
     * @param self The prediction market
     * @return liquidity Calculated net liquidity amount
     */
    function netLiquidity(PredictionMarket memory self) internal pure returns (uint256 liquidity) {
        return self.liquidity - self.fees;
    }

    /**
     * @notice Whether swaps can be facilitated in the market
     * @dev If a market has liquidity on only 1 side, then a swap is not possible
     * @param self The prediction market
     */
    function canSwap(PredictionMarket memory self) internal view returns (bool) {
        return isActive(self) && self.balanceBear * self.balanceBull != 0;
    }

    /**
     * @notice Add liquidity to a given market 
     * @dev Credits msg.sender with value of bull/bear units and increments liquidity.
     * @param self The prediction market
     * @param amount The deposited liquidity amount
     * @param side The side to add liquidit to
     * @param feePercentage The fee amount
     * @param preview whether the calc should update the market
     * @return bullAmount The bull amount of units credited
     * @return bearAmount The bear amount of units credited
     */
    function addLiquidity(
        PredictionMarket memory self,
        Side side,
        uint256 amount,
        uint256 feePercentage,
        bool preview
    ) internal pure returns (uint256 bullAmount, uint256 bearAmount) {
        (uint256 quoteBull, uint256 quoteBear) = quote(self);
        (uint256 bullAmountIn, uint256 bearAmountIn) = (0,0);

        if(side == Side.Bear){
            bearAmountIn = amount;
        } else if(side == Side.Bull){
            bullAmountIn = amount;
        } else if(side == Side.Both){
            bullAmountIn = amount/2;
            bearAmountIn = amount/2;
        }

        bullAmount = bullAmountIn > 0 ? Math.mulDiv(bullAmountIn, 1e18, quoteBull) : 0;
        bearAmount = bearAmountIn > 0 ? Math.mulDiv(bearAmountIn, 1e18, quoteBear) : 0;

        if(preview){
            return (bullAmount, bearAmount);
        }

        // adjust the market balances based on the calculated values
        self.liquidity += amount;
        self.balanceBear += bearAmount;
        self.balanceBull += bullAmount;
        self.fees += _calculateFees(amount, feePercentage);
    }

    /**
     * @notice get the fee amount given an amount and fee percentage
     * @param amount The total amount
     * @param feePercentage The fee amount
     * @return fee The calculated fee amount
     */
    function _calculateFees(
        uint256 amount,
        uint256 feePercentage
    ) private pure returns (uint256 fee) {
        return Math.mulDiv(amount, feePercentage, 1e6);
    }

    /**
     * @notice Given an input amount and side, returns the maximum output amount of the other side
     * @param self The prediction market
     * @param amountIn The deposited liquidity amount
     * @param side Side to swap FROM
     * @param feeAmount Fee percentage to charge for the swap
     * @return amountOut Output amount
     * @return fees The fee amount collected for the swap
     */
    function getAmountOut(
        PredictionMarket memory self,
        Side side,
        uint256 amountIn,
        uint256 feeAmount
    ) internal pure returns (uint256 amountOut, uint256 fees) {
        (uint256 reserveIn, uint256 reserveOut) = side == Side.Bull ? 
            (self.balanceBull, self.balanceBear) :
            (self.balanceBear, self.balanceBull);

        uint256 amountInAfterFees = Math.mulDiv(amountIn, 1e6-feeAmount, 1e6);
        uint256 denominator = reserveIn * 1e6;

        amountOut = Math.mulDiv(amountInAfterFees, reserveOut, denominator);
        fees = amountIn - amountInAfterFees;
    }

    /**
     * @notice Swap the given input amount and side from one side to the other
     * @dev Swap fees are accumulated and deducted during market settlement
     * @param self The prediction market
     * @param amountIn The deposited liquidity amount
     * @param side Side to swap FROM
     * @param feeAmount Fee percentage to charge for the swap
     * @return amountOut Units in the opposing side quoted from the swap
     */
    function swap(
        PredictionMarket memory self,
        Side side,
        uint256 amountIn,
        uint256 feeAmount
    ) internal view returns (uint256 amountOut) {
        // revert if the market has 0 liquidity on either side
        if(!canSwap(self)){
            revert CannotSwapInMarket();
        }

        // determine the output amount based on the side and amountIn 
        uint256 fees;

        (amountOut, fees) = getAmountOut(self, side, amountIn, feeAmount);

        self.fees += fees;

        // update the market to reflect the swap
        if(side == Side.Bull){
            self.balanceBull -= amountIn;
            self.balanceBear += amountOut;
        } else {
            self.balanceBear -= amountIn;
            self.balanceBull += amountOut;
        }
    }

    

}