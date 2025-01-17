// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../adl/AdlUtils.sol";

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "./DepositVault.sol";
import "./DepositStoreUtils.sol";
import "./DepositEventUtils.sol";

import "../nonce/NonceUtils.sol";
import "../pricing/SwapPricingUtils.sol";
import "../oracle/Oracle.sol";
import "../oracle/OracleUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";

import "../utils/Array.sol";
import "../utils/RevertUtils.sol";

// @title DepositUtils
// @dev Library for deposit functions, to help with the depositing of liquidity
// into a market in return for market tokens
library DepositUtils {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Array for uint256[];

    using Price for Price.Props;
    using Deposit for Deposit.Props;

    // @dev CreateDepositParams struct used in createDeposit to avoid stack
    // too deep errors
    //
    // @param receiver the address to send the market tokens to
    // @param callbackContract the callback contract
    // @param market the market to deposit into
    // @param minMarketTokens the minimum acceptable number of liquidity tokens
    // @param shouldUnwrapNativeToken whether to unwrap the native token when
    // sending funds back to the user in case the deposit gets cancelled
    // @param executionFee the execution fee for keepers
    // @param callbackGasLimit the gas limit for the callbackContract
    struct CreateDepositParams {
        address receiver;
        address callbackContract;
        address market;
        uint256 minMarketTokens;
        bool shouldUnwrapNativeToken;
        uint256 executionFee;
        uint256 callbackGasLimit;
    }

    // @dev ExecuteDepositParams struct used in executeDeposit to avoid stack
    // too deep errors
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param oracle Oracle
    // @param key the key of the deposit to execute
    // @param oracleBlockNumbers the oracle block numbers for the prices in oracle
    // @param keeper the address of the keeper executing the deposit
    // @param startingGas the starting amount of gas
    struct ExecuteDepositParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        DepositVault depositVault;
        Oracle oracle;
        bytes32 key;
        uint256[] oracleBlockNumbers;
        address keeper;
        uint256 startingGas;
    }

    // @dev _ExecuteDepositParams struct used in executeDeposit to avoid stack
    // too deep errors
    //
    // @param market the market to deposit into
    // @param account the depositing account
    // @param receiver the account to send the market tokens to
    // @param tokenIn the token to deposit, either the market.longToken or
    // market.shortToken
    // @param tokenOut the other token, if tokenIn is market.longToken then
    // tokenOut is market.shortToken and vice versa
    // @param tokenInPrice price of tokenIn
    // @param tokenOutPrice price of tokenOut
    // @param amount amount of tokenIn
    // @param priceImpactUsd price impact in USD
    struct _ExecuteDepositParams {
        Market.Props market;
        address account;
        address receiver;
        address tokenIn;
        address tokenOut;
        Price.Props tokenInPrice;
        Price.Props tokenOutPrice;
        uint256 amount;
        int256 priceImpactUsd;
    }

    error MinMarketTokens(uint256 received, uint256 expected);

    // @dev creates a deposit
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param account the depositing account
    // @param params CreateDepositParams
    function createDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        address account,
        CreateDepositParams memory params
    ) external returns (bytes32) {
        Market.Props memory market = MarketUtils.getEnabledMarket(dataStore, params.market);

        uint256 longTokenAmount = depositVault.recordTransferIn(market.longToken);
        uint256 shortTokenAmount = depositVault.recordTransferIn(market.shortToken);

        address wnt = TokenUtils.wnt(dataStore);

        if (market.longToken == wnt) {
            longTokenAmount -= params.executionFee;
        } else if (market.shortToken == wnt) {
            shortTokenAmount -= params.executionFee;
        } else {
            uint256 wntAmount = depositVault.recordTransferIn(wnt);
            require(wntAmount >= params.executionFee, "DepositUtils: invalid wntAmount");

            GasUtils.handleExcessExecutionFee(
                dataStore,
                depositVault,
                wntAmount,
                params.executionFee
            );
        }

        if (longTokenAmount == 0 && shortTokenAmount == 0) {
            revert("DepositUtils: empty deposit");
        }

        Deposit.Props memory deposit = Deposit.Props(
            Deposit.Addresses(
                account,
                params.receiver,
                params.callbackContract,
                market.marketToken
            ),
            Deposit.Numbers(
                longTokenAmount,
                shortTokenAmount,
                params.minMarketTokens,
                Chain.currentBlockNumber(),
                params.executionFee,
                params.callbackGasLimit
            ),
            Deposit.Flags(
                params.shouldUnwrapNativeToken
            )
        );

        CallbackUtils.validateCallbackGasLimit(dataStore, deposit.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteDepositGasLimit(dataStore, deposit);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, params.executionFee);

        bytes32 key = NonceUtils.getNextKey(dataStore);

        DepositStoreUtils.set(dataStore, key, deposit);

        DepositEventUtils.emitDepositCreated(eventEmitter, key, deposit);

        return key;
    }

    // @dev executes a deposit
    // @param params ExecuteDepositParams
    function executeDeposit(ExecuteDepositParams memory params) external {
        Deposit.Props memory deposit = DepositStoreUtils.get(params.dataStore, params.key);

        require(deposit.account() != address(0), "DepositUtils: empty deposit");
        require(deposit.longTokenAmount() > 0 || deposit.shortTokenAmount() > 0, "DepositUtils: empty deposit amount");

        if (!params.oracleBlockNumbers.areEqualTo(deposit.updatedAtBlock())) {
            OracleUtils.revertOracleBlockNumbersAreNotEqual(params.oracleBlockNumbers, deposit.updatedAtBlock());
        }

        Market.Props memory market = MarketUtils.getEnabledMarket(params.dataStore, deposit.market());
        MarketUtils.MarketPrices memory prices = MarketUtils.getMarketPrices(params.oracle, market);

        // deposits should improve the pool state but it should be checked if
        // there is any pending ADL before allowing deposits
        // this prevents deposits before a pending ADL is completed
        // so that market tokens are not minted at a lower price than they
        // should be
        AdlUtils.validatePoolState(
            params.dataStore,
            market,
            prices,
            false
        );

        uint256 longTokenUsd = deposit.longTokenAmount() * prices.longTokenPrice.midPrice();
        uint256 shortTokenUsd = deposit.shortTokenAmount() * prices.shortTokenPrice.midPrice();

        uint256 receivedMarketTokens;

        int256 priceImpactUsd = SwapPricingUtils.getPriceImpactUsd(
            SwapPricingUtils.GetPriceImpactUsdParams(
                params.dataStore,
                market.marketToken,
                market.longToken,
                market.shortToken,
                prices.longTokenPrice.midPrice(),
                prices.shortTokenPrice.midPrice(),
                (deposit.longTokenAmount() * prices.longTokenPrice.midPrice()).toInt256(),
                (deposit.shortTokenAmount() * prices.shortTokenPrice.midPrice()).toInt256()
            )
        );

        // since tokens were recorded as transferred in during the createDeposit step
        // to save gas costs we assume that _transferOut should always correctly transfer the tokens
        // to the marketToken
        // it is possible for a token to return true even if the transfer is not entirely fulfilled
        // this should still work unless the token has custom behavior that conditionally blocks transfers
        // even if the sender has sufficient balance
        // this will not work correctly for tokens with a burn mechanism, those need to be separately handled
        if (deposit.longTokenAmount() > 0) {
            params.depositVault.transferOut(market.longToken, market.marketToken, deposit.longTokenAmount());

            _ExecuteDepositParams memory _params = _ExecuteDepositParams(
                market,
                deposit.account(),
                deposit.receiver(),
                market.longToken,
                market.shortToken,
                prices.longTokenPrice,
                prices.shortTokenPrice,
                deposit.longTokenAmount(),
                priceImpactUsd * longTokenUsd.toInt256() / (longTokenUsd + shortTokenUsd).toInt256()
            );

            receivedMarketTokens += _executeDeposit(params, _params);
        }

        if (deposit.shortTokenAmount() > 0) {
            params.depositVault.transferOut(market.shortToken, market.marketToken, deposit.shortTokenAmount());

            _ExecuteDepositParams memory _params = _ExecuteDepositParams(
                market,
                deposit.account(),
                deposit.receiver(),
                market.shortToken,
                market.longToken,
                prices.shortTokenPrice,
                prices.longTokenPrice,
                deposit.shortTokenAmount(),
                priceImpactUsd * shortTokenUsd.toInt256() / (longTokenUsd + shortTokenUsd).toInt256()
            );

            receivedMarketTokens += _executeDeposit(params, _params);
        }

        if (receivedMarketTokens < deposit.minMarketTokens()) {
            revert MinMarketTokens(receivedMarketTokens, deposit.minMarketTokens());
        }

        DepositStoreUtils.remove(params.dataStore, params.key, deposit.account());

        DepositEventUtils.emitDepositExecuted(params.eventEmitter, params.key);

        CallbackUtils.afterDepositExecution(params.key, deposit);

        GasUtils.payExecutionFee(
            params.dataStore,
            params.depositVault,
            deposit.executionFee(),
            params.startingGas,
            params.keeper,
            deposit.account()
        );
    }

    // @dev cancels a deposit, funds are sent back to the user
    //
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param depositVault DepositVault
    // @param key the key of the deposit to cancel
    // @param keeper the address of the keeper
    // @param startingGas the starting gas amount
    function cancelDeposit(
        DataStore dataStore,
        EventEmitter eventEmitter,
        DepositVault depositVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        Deposit.Props memory deposit = DepositStoreUtils.get(dataStore, key);
        require(deposit.account() != address(0), "DepositUtils: empty deposit");

        Market.Props memory market = MarketUtils.getEnabledMarket(dataStore, deposit.market());

        if (deposit.longTokenAmount() > 0) {
            depositVault.transferOut(
                market.longToken,
                deposit.account(),
                deposit.longTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        if (deposit.shortTokenAmount() > 0) {
            depositVault.transferOut(
                market.shortToken,
                deposit.account(),
                deposit.shortTokenAmount(),
                deposit.shouldUnwrapNativeToken()
            );
        }

        DepositStoreUtils.remove(dataStore, key, deposit.account());

        DepositEventUtils.emitDepositCancelled(eventEmitter, key, reason, reasonBytes);

        CallbackUtils.afterDepositCancellation(key, deposit);

        GasUtils.payExecutionFee(
            dataStore,
            depositVault,
            deposit.executionFee(),
            startingGas,
            keeper,
            deposit.account()
        );
    }

    // @dev executes a deposit
    // @param params ExecuteDepositParams
    // @param _params _ExecuteDepositParams
    function _executeDeposit(ExecuteDepositParams memory params, _ExecuteDepositParams memory _params) internal returns (uint256) {
        SwapPricingUtils.SwapFees memory fees = SwapPricingUtils.getSwapFees(
            params.dataStore,
            _params.market.marketToken,
            _params.amount
        );

        FeeUtils.incrementClaimableFeeAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            fees.feeReceiverAmount,
            Keys.DEPOSIT_FEE
        );

        SwapPricingUtils.emitSwapFeesCollected(
            params.eventEmitter,
             _params.market.marketToken,
             _params.tokenIn,
             "deposit",
             fees
         );

        return _processDeposit(params, _params, fees.amountAfterFees, fees.feesForPool);
    }

    // @dev processes a deposit
    // @param params ExecuteDepositParams
    // @param _params _ExecuteDepositParams
    // @param amountAfterFees the deposit amount after fees
    // @param feesForPool the amount of fees for the pool
    function _processDeposit(
        ExecuteDepositParams memory params,
        _ExecuteDepositParams memory _params,
        uint256 amountAfterFees,
        uint256 feesForPool
    ) internal returns (uint256) {
        uint256 mintAmount;

        int256 _poolValue = MarketUtils.getPoolValue(
            params.dataStore,
            _params.market,
            _params.tokenIn == _params.market.longToken ? _params.tokenInPrice : _params.tokenOutPrice,
            _params.tokenIn == _params.market.shortToken ? _params.tokenInPrice : _params.tokenOutPrice,
            params.oracle.getPrimaryPrice(_params.market.indexToken),
            true
        );

        if (_poolValue < 0) {
            revert("Invalid pool state");
        }

        uint256 poolValue = _poolValue.toUint256();

        uint256 supply = MarketUtils.getMarketTokenSupply(MarketToken(payable(_params.market.marketToken)));

        if (_params.priceImpactUsd > 0) {
            // when there is a positive price impact factor,
            // tokens from the swap impact pool are used to mint additional market tokens for the user
            // for example, if 50,000 USDC is deposited and there is a positive price impact
            // an additional 0.005 ETH may be used to mint market tokens
            // the swap impact pool is decreased by the used amount
            //
            // priceImpactUsd is calculated based on pricing assuming only depositAmount of tokenIn
            // was added to the pool
            // since impactAmount of tokenOut is added to the pool here, the calculation of
            // the tokenInPrice would not be entirely accurate
            int256 positiveImpactAmount = MarketUtils.applySwapImpactWithCap(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                _params.tokenOut,
                _params.tokenOutPrice,
                _params.priceImpactUsd
            );

            // calculate the usd amount using positiveImpactAmount since it may
            // be capped by the max available amount in the impact pool
            mintAmount += MarketUtils.usdToMarketTokenAmount(
                positiveImpactAmount.toUint256() * _params.tokenOutPrice.min,
                poolValue,
                supply
            );

            // deposit the token out, that was withdrawn from the impact pool, to mint market tokens
            MarketUtils.applyDeltaToPoolAmount(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                _params.tokenOut,
                positiveImpactAmount
            );
        } else {
            // when there is a negative price impact factor,
            // less of the deposit amount is used to mint market tokens
            // for example, if 10 ETH is deposited and there is a negative price impact
            // only 9.995 ETH may be used to mint market tokens
            // the remaining 0.005 ETH will be stored in the swap impact pool
            int256 negativeImpactAmount = MarketUtils.applySwapImpactWithCap(
                params.dataStore,
                params.eventEmitter,
                _params.market.marketToken,
                _params.tokenIn,
                _params.tokenInPrice,
                _params.priceImpactUsd
            );
            amountAfterFees -= (-negativeImpactAmount).toUint256();
        }

        mintAmount += MarketUtils.usdToMarketTokenAmount(
            amountAfterFees * _params.tokenInPrice.min,
            poolValue,
            supply
        );

        MarketUtils.applyDeltaToPoolAmount(
            params.dataStore,
            params.eventEmitter,
            _params.market.marketToken,
            _params.tokenIn,
            (amountAfterFees + feesForPool).toInt256()
        );

        MarketUtils.validatePoolAmount(
            params.dataStore,
            _params.market.marketToken,
            _params.tokenIn
        );

        MarketToken(payable(_params.market.marketToken)).mint(_params.receiver, mintAmount);

        return mintAmount;
    }
}
