// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../data/Keys.sol";

import "./Order.sol";
import "./OrderVault.sol";
import "./OrderStoreUtils.sol";
import "./OrderEventUtils.sol";

import "../nonce/NonceUtils.sol";
import "../oracle/Oracle.sol";
import "../oracle/OracleUtils.sol";
import "../event/EventEmitter.sol";

import "./IncreaseOrderUtils.sol";
import "./DecreaseOrderUtils.sol";
import "./SwapOrderUtils.sol";
import "./BaseOrderUtils.sol";

import "../swap/SwapUtils.sol";

import "../gas/GasUtils.sol";
import "../callback/CallbackUtils.sol";

import "../utils/Array.sol";

// @title OrderUtils
// @dev Library for order functions
library OrderUtils {
    using Order for Order.Props;
    using Position for Position.Props;
    using Price for Price.Props;
    using Array for uint256[];

    // @dev creates an order in the order store
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param account the order account
    // @param params BaseOrderUtils.CreateOrderParams
    function createOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        address account,
        BaseOrderUtils.CreateOrderParams memory params
    ) external returns (bytes32) {
        uint256 initialCollateralDeltaAmount;

        address wnt = TokenUtils.wnt(dataStore);

        bool shouldRecordSeparateExecutionFeeTransfer = true;

        if (
            params.orderType == Order.OrderType.MarketSwap ||
            params.orderType == Order.OrderType.LimitSwap ||
            params.orderType == Order.OrderType.MarketIncrease ||
            params.orderType == Order.OrderType.LimitIncrease
        ) {
            initialCollateralDeltaAmount = orderVault.recordTransferIn(params.addresses.initialCollateralToken);
            if (params.addresses.initialCollateralToken == wnt) {
                require(initialCollateralDeltaAmount >= params.numbers.executionFee, "OrderUtils: invalid executionFee");
                initialCollateralDeltaAmount -= params.numbers.executionFee;
                shouldRecordSeparateExecutionFeeTransfer = false;
            }
        } else if (
            params.orderType == Order.OrderType.MarketDecrease ||
            params.orderType == Order.OrderType.LimitDecrease ||
            params.orderType == Order.OrderType.StopLossDecrease
        ) {
            initialCollateralDeltaAmount = params.numbers.initialCollateralDeltaAmount;
        }

        if (shouldRecordSeparateExecutionFeeTransfer) {
            uint256 wntAmount = orderVault.recordTransferIn(wnt);
            require(wntAmount >= params.numbers.executionFee, "OrderUtils: invalid wntAmount");

            GasUtils.handleExcessExecutionFee(
                dataStore,
                orderVault,
                wntAmount,
                params.numbers.executionFee
            );
        }

        if (BaseOrderUtils.isDecreaseOrder(params.orderType) && params.addresses.swapPath.length > 0) {
            require(params.addresses.swapPath[0] == params.addresses.market, "OrderUtils: invalid swap path");
        }

        // validate swap path markets
        MarketUtils.getEnabledMarkets(
            dataStore,
            params.addresses.swapPath,
            BaseOrderUtils.isDecreaseOrder(params.orderType)
        );

        Order.Props memory order;

        order.setAccount(account);
        order.setReceiver(params.addresses.receiver);
        order.setCallbackContract(params.addresses.callbackContract);
        order.setMarket(params.addresses.market);
        order.setInitialCollateralToken(params.addresses.initialCollateralToken);
        order.setSwapPath(params.addresses.swapPath);
        order.setSizeDeltaUsd(params.numbers.sizeDeltaUsd);
        order.setInitialCollateralDeltaAmount(initialCollateralDeltaAmount);
        order.setTriggerPrice(params.numbers.triggerPrice);
        order.setAcceptablePrice(params.numbers.acceptablePrice);
        order.setExecutionFee(params.numbers.executionFee);
        order.setCallbackGasLimit(params.numbers.callbackGasLimit);
        order.setMinOutputAmount(params.numbers.minOutputAmount);
        order.setOrderType(params.orderType);
        order.setIsLong(params.isLong);
        order.setShouldUnwrapNativeToken(params.shouldUnwrapNativeToken);

        CallbackUtils.validateCallbackGasLimit(dataStore, order.callbackGasLimit());

        uint256 estimatedGasLimit = GasUtils.estimateExecuteOrderGasLimit(dataStore, order);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, order.executionFee());

        bytes32 key = NonceUtils.getNextKey(dataStore);

        order.touch();
        OrderStoreUtils.set(dataStore, key, order);

        OrderEventUtils.emitOrderCreated(eventEmitter, key, order);

        return key;
    }

    // @dev executes an order
    // @param params BaseOrderUtils.ExecuteOrderParams
    function executeOrder(BaseOrderUtils.ExecuteOrderParams memory params) external {
        BaseOrderUtils.validateNonEmptyOrder(params.order);

        BaseOrderUtils.setExactOrderPrice(
            params.contracts.oracle,
            params.market.indexToken,
            params.order.orderType(),
            params.order.triggerPrice(),
            params.order.isLong()
        );

        processOrder(params);

        OrderEventUtils.emitOrderExecuted(params.contracts.eventEmitter, params.key);

        CallbackUtils.afterOrderExecution(params.key, params.order);

        GasUtils.payExecutionFee(
            params.contracts.dataStore,
            params.contracts.orderVault,
            params.order.executionFee(),
            params.startingGas,
            params.keeper,
            params.order.account()
        );
    }

    // @dev process an order execution
    // @param params BaseOrderUtils.ExecuteOrderParams
    function processOrder(BaseOrderUtils.ExecuteOrderParams memory params) internal {
        if (BaseOrderUtils.isIncreaseOrder(params.order.orderType())) {
            IncreaseOrderUtils.processOrder(params);
            return;
        }

        if (BaseOrderUtils.isDecreaseOrder(params.order.orderType())) {
            DecreaseOrderUtils.processOrder(params);
            return;
        }

        if (BaseOrderUtils.isSwapOrder(params.order.orderType())) {
            SwapOrderUtils.processOrder(params);
            return;
        }

        BaseOrderUtils.revertUnsupportedOrderType();
    }

    // @dev cancels an order
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param key the key of the order to cancel
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas of the transaction
    // @param reason the reason for cancellation
    function cancelOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        Order.Props memory order = OrderStoreUtils.get(dataStore, key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        if (BaseOrderUtils.isIncreaseOrder(order.orderType()) || BaseOrderUtils.isSwapOrder(order.orderType())) {
            if (order.initialCollateralDeltaAmount() > 0) {
                orderVault.transferOut(
                    order.initialCollateralToken(),
                    order.account(),
                    order.initialCollateralDeltaAmount(),
                    order.shouldUnwrapNativeToken()
                );
            }
        }

        OrderStoreUtils.remove(dataStore, key, order.account());

        OrderEventUtils.emitOrderCancelled(eventEmitter, key, reason, reasonBytes);

        CallbackUtils.afterOrderCancellation(key, order);

        GasUtils.payExecutionFee(
            dataStore,
            orderVault,
            order.executionFee(),
            startingGas,
            keeper,
            order.account()
        );
    }

    // @dev freezes an order
    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param key the key of the order to freeze
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas of the transaction
    // @param reason the reason the order was frozen
    function freezeOrder(
        DataStore dataStore,
        EventEmitter eventEmitter,
        OrderVault orderVault,
        bytes32 key,
        address keeper,
        uint256 startingGas,
        string memory reason,
        bytes memory reasonBytes
    ) external {
        Order.Props memory order = OrderStoreUtils.get(dataStore, key);
        BaseOrderUtils.validateNonEmptyOrder(order);

        if (order.isFrozen()) {
            revert("Order already frozen");
        }

        uint256 executionFee = order.executionFee();

        order.setExecutionFee(0);
        order.setIsFrozen(true);
        OrderStoreUtils.set(dataStore, key, order);

        GasUtils.payExecutionFee(
            dataStore,
            orderVault,
            executionFee,
            startingGas,
            keeper,
            order.account()
        );

        OrderEventUtils.emitOrderFrozen(eventEmitter, key, reason, reasonBytes);

        CallbackUtils.afterOrderFrozen(key, order);
    }
}
