// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../adl/AdlUtils.sol";
import "../data/DataStore.sol";
import "../event/EventEmitter.sol";
import "../oracle/Oracle.sol";
import "../pricing/SwapPricingUtils.sol";
import "../token/TokenUtils.sol";
import "../fee/FeeUtils.sol";

/**
 * @title SwapUtils
 * @dev Library for swap functions
 */
library SwapUtils {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Price for Price.Props;

    using EventUtils for EventUtils.AddressItems;
    using EventUtils for EventUtils.UintItems;
    using EventUtils for EventUtils.IntItems;
    using EventUtils for EventUtils.BoolItems;
    using EventUtils for EventUtils.Bytes32Items;
    using EventUtils for EventUtils.BytesItems;
    using EventUtils for EventUtils.StringItems;

    /**
     * @param dataStore The contract that provides access to data stored on-chain.
     * @param eventEmitter The contract that emits events.
     * @param oracle The contract that provides access to price data from oracles.
     * @param tokenIn The address of the token that is being swapped.
     * @param amountIn The amount of the token that is being swapped.
     * @param markets An array of market properties, specifying the markets in which the swap should be executed.
     * @param minOutputAmount The minimum amount of tokens that should be received as part of the swap.
     * @param receiver The address to which the swapped tokens should be sent.
     * @param shouldUnwrapNativeToken A boolean indicating whether the received tokens should be unwrapped from the wrapped native token (WNT) if they are wrapped.
     */
    struct SwapParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        Oracle oracle;
        address tokenIn;
        uint256 amountIn;
        Market.Props[] markets;
        uint256 minOutputAmount;
        address receiver;
        bool shouldUnwrapNativeToken;
    }

    /**
     * @param market The market in which the swap should be executed.
     * @param tokenIn The address of the token that is being swapped.
     * @param amountIn The amount of the token that is being swapped.
     * @param receiver The address to which the swapped tokens should be sent.
     * @param shouldUnwrapNativeToken A boolean indicating whether the received tokens should be unwrapped from the wrapped native token (WNT) if they are wrapped.
     */
    struct _SwapParams {
        Market.Props market;
        address tokenIn;
        uint256 amountIn;
        address receiver;
        bool shouldUnwrapNativeToken;
    }

    /**
     * @param tokenOut The address of the token that is being received as part of the swap.
     * @param tokenInPrice The price of the token that is being swapped.
     * @param tokenOutPrice The price of the token that is being received as part of the swap.
     * @param amountIn The amount of the token that is being swapped.
     * @param amountOut The amount of the token that is being received as part of the swap.
     * @param poolAmountOut The total amount of the token that is being received by all users in the swap pool.
     */
    struct _SwapCache {
        address tokenOut;
        Price.Props tokenInPrice;
        Price.Props tokenOutPrice;
        uint256 amountIn;
        uint256 amountOut;
        uint256 poolAmountOut;
    }

    event SwapReverted(string reason, bytes reasonBytes);

    error InvalidTokenIn(address tokenIn, address market);
    error InsufficientSwapOutputAmount(uint256 outputAmount, uint256 minOutputAmount);

    /**
     * @dev Swaps a given amount of a given token for another token based on a
     * specified swap path.
     * @param params The parameters for the swap.
     * @return A tuple containing the address of the token that was received as
     * part of the swap and the amount of the received token.
     */
    function swap(SwapParams memory params) external returns (address, uint256) {
        address tokenOut = params.tokenIn;
        uint256 outputAmount = params.amountIn;

        for (uint256 i = 0; i < params.markets.length; i++) {
            Market.Props memory market = params.markets[i];
            uint256 nextIndex = i + 1;
            address receiver;
            if (nextIndex < params.markets.length) {
                receiver = params.markets[nextIndex].marketToken;
            } else {
                receiver = params.receiver;
            }

            _SwapParams memory _params = _SwapParams(
                market,
                tokenOut,
                outputAmount,
                receiver,
                i == params.markets.length - 1 ? params.shouldUnwrapNativeToken : false // only convert ETH on the last swap if needed
            );
            (tokenOut, outputAmount) = _swap(params, _params);
        }

        if (outputAmount < params.minOutputAmount) {
            revert(Keys.INSUFFICIENT_SWAP_OUTPUT_ERROR);
        }

        return (tokenOut, outputAmount);
    }

    /**
     * Performs a swap on a single market.
     *
     * @param params  The parameters for the swap.
     * @param _params The parameters for the swap on this specific market.
     * @return The token and amount that was swapped.
     */
    function _swap(SwapParams memory params, _SwapParams memory _params) internal returns (address, uint256) {
        _SwapCache memory cache;

        if (_params.tokenIn != _params.market.longToken && _params.tokenIn != _params.market.shortToken) {
            revert InvalidTokenIn(_params.tokenIn, _params.market.marketToken);
        }

        cache.tokenOut = MarketUtils.getOppositeToken(_params.tokenIn, _params.market);
        cache.tokenInPrice = params.oracle.getLatestPrice(_params.tokenIn);
        cache.tokenOutPrice = params.oracle.getLatestPrice(cache.tokenOut);

        SwapPricingUtils.SwapFees memory fees = SwapPricingUtils.getSwapFees(
            params.dataStore,
            _params.market.marketToken,
            _params.amountIn
        );

        FeeUtils.incrementClaimableFeeAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            fees.feeReceiverAmount,
            Keys.SWAP_FEE
        );

        int256 priceImpactUsd = SwapPricingUtils.getPriceImpactUsd(
            SwapPricingUtils.GetPriceImpactUsdParams(
                params.dataStore,
                _params.market.marketToken,
                _params.tokenIn,
                cache.tokenOut,
                cache.tokenInPrice.midPrice(),
                cache.tokenOutPrice.midPrice(),
                (fees.amountAfterFees * cache.tokenInPrice.midPrice()).toInt256(),
                -(fees.amountAfterFees * cache.tokenInPrice.midPrice()).toInt256()
            )
        );

        if (priceImpactUsd > 0) {
            // when there is a positive price impact factor, additional tokens from the swap impact pool
            // are withdrawn for the user
            // for example, if 50,000 USDC is swapped out and there is a positive price impact
            // an additional 100 USDC may be sent to the user
            // the swap impact pool is decreased by the used amount

            cache.amountIn = fees.amountAfterFees;
            // round amountOut down
            cache.amountOut = cache.amountIn * cache.tokenInPrice.min / cache.tokenOutPrice.max;
            cache.poolAmountOut = cache.amountOut;

            int256 positiveImpactAmount = MarketUtils.applySwapImpactWithCap(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                cache.tokenOut,
                cache.tokenOutPrice,
                priceImpactUsd
            );

            cache.amountOut += positiveImpactAmount.toUint256();
        } else {
            // when there is a negative price impact factor,
            // less of the input amount is sent to the pool
            // for example, if 10 ETH is swapped in and there is a negative price impact
            // only 9.995 ETH may be swapped in
            // the remaining 0.005 ETH will be stored in the swap impact pool

            int256 negativeImpactAmount = MarketUtils.applySwapImpactWithCap(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                _params.tokenIn,
                cache.tokenInPrice,
                priceImpactUsd
            );

            cache.amountIn = fees.amountAfterFees - (-negativeImpactAmount).toUint256();
            cache.amountOut = cache.amountIn * cache.tokenInPrice.min / cache.tokenOutPrice.max;
            cache.poolAmountOut = cache.amountOut;
        }

        // the amountOut value includes the positive price impact amount
        if (_params.receiver != _params.market.marketToken) {
            MarketToken(payable(_params.market.marketToken)).transferOut(
                cache.tokenOut,
                _params.receiver,
                cache.amountOut,
                _params.shouldUnwrapNativeToken
            );
        }

        MarketUtils.applyDeltaToPoolAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            (cache.amountIn + fees.feesForPool).toInt256()
        );

        // the poolAmountOut excludes the positive price impact amount
        // as that is deducted from the swap impact pool instead
        MarketUtils.applyDeltaToPoolAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            cache.tokenOut,
            -cache.poolAmountOut.toInt256()
        );

        MarketUtils.MarketPrices memory prices = MarketUtils.MarketPrices(
            params.oracle.getLatestPrice(_params.market.indexToken),
            _params.tokenIn == _params.market.longToken ? cache.tokenInPrice : cache.tokenOutPrice,
            _params.tokenIn == _params.market.shortToken ? cache.tokenInPrice : cache.tokenOutPrice
        );

        MarketUtils.validatePoolAmount(
            params.dataStore,
            _params.market.marketToken,
            _params.tokenIn
        );

        MarketUtils.validateReserve(
            params.dataStore,
            _params.market,
            prices,
            cache.tokenOut == _params.market.longToken
        );

        AdlUtils.validatePoolState(
            params.dataStore,
            _params.market,
            prices,
            true
        );

        SwapPricingUtils.emitSwapInfo(
            params.eventEmitter,
            _params.market.marketToken,
            _params.receiver,
            _params.tokenIn,
            cache.tokenOut,
            cache.tokenInPrice.min,
            cache.tokenOutPrice.max,
            _params.amountIn,
            cache.amountIn,
            cache.amountOut,
            priceImpactUsd
        );

        SwapPricingUtils.emitSwapFeesCollected(
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            "swap",
            fees
        );

        return (cache.tokenOut, cache.amountOut);
    }
}
