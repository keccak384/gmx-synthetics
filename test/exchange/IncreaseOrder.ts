import { expect } from "chai";

import { deployFixture } from "../../utils/fixture";
import { expandDecimals, decimalToFloat } from "../../utils/math";
import { handleDeposit } from "../../utils/deposit";
import { OrderType, createOrder, executeOrder, handleOrder } from "../../utils/order";
import * as keys from "../../utils/keys";

describe("Exchange.IncreaseOrder", () => {
  const { provider } = ethers;

  let fixture;
  let user0, user1;
  let dataStore, orderStore, positionStore, ethUsdMarket, wnt;
  let executionFee;

  beforeEach(async () => {
    fixture = await deployFixture();
    ({ user0, user1 } = fixture.accounts);
    ({ dataStore, orderStore, positionStore, ethUsdMarket, wnt } = fixture.contracts);
    ({ executionFee } = fixture.props);

    await handleDeposit(fixture, {
      create: {
        market: ethUsdMarket,
        longTokenAmount: expandDecimals(1000, 18),
      },
    });
  });

  it("createOrder", async () => {
    expect(await orderStore.getOrderCount()).eq(0);
    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [ethUsdMarket.marketToken],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee,
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
      gasUsageLabel: "createOrder",
    };

    await createOrder(fixture, params);

    expect(await orderStore.getOrderCount()).eq(1);

    const block = await provider.getBlock();

    const orderKeys = await orderStore.getOrderKeys(0, 1);
    const order = await orderStore.get(orderKeys[0]);

    expect(order.addresses.account).eq(user0.address);
    expect(order.addresses.market).eq(ethUsdMarket.marketToken);
    expect(order.addresses.initialCollateralToken).eq(wnt.address);
    expect(order.addresses.swapPath).eql([ethUsdMarket.marketToken]);
    expect(order.numbers.sizeDeltaUsd).eq(decimalToFloat(200 * 1000));
    expect(order.numbers.initialCollateralDeltaAmount).eq(expandDecimals(10, 18));
    expect(order.numbers.acceptablePrice).eq(expandDecimals(5001, 12));
    expect(order.numbers.executionFee).eq(expandDecimals(1, 15));
    expect(order.numbers.minOutputAmount).eq(expandDecimals(50000, 6));
    expect(order.numbers.updatedAtBlock).eq(block.number);
    expect(order.flags.orderType).eq(OrderType.MarketIncrease);
    expect(order.flags.isLong).eq(true);
    expect(order.flags.shouldUnwrapNativeToken).eq(false);
  });

  it("executeOrder", async () => {
    expect(await orderStore.getOrderCount()).eq(0);

    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee: expandDecimals(1, 15),
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, params);

    expect(await orderStore.getOrderCount()).eq(1);
    expect(await positionStore.getAccountPositionCount(user0.address)).eq(0);
    expect(await positionStore.getPositionCount()).eq(0);

    await executeOrder(fixture, {
      gasUsageLabel: "executeOrder",
    });

    expect(await orderStore.getOrderCount()).eq(0);
    expect(await positionStore.getAccountPositionCount(user0.address)).eq(1);
    expect(await positionStore.getPositionCount()).eq(1);

    params.account = user1;

    await handleOrder(fixture, {
      create: params,
      execute: {
        gasUsageLabel: "executeOrder",
      },
    });

    expect(await positionStore.getAccountPositionCount(user1.address)).eq(1);
    expect(await positionStore.getPositionCount()).eq(2);
  });

  it("executeOrder with price impact", async () => {
    // set price impact to 0.1% for every $50,000 of token imbalance
    // 0.1% => 0.001
    // 0.001 / 50,000 => 2 * (10 ** -8)
    await dataStore.setUint(keys.positionImpactFactorKey(ethUsdMarket.marketToken, true), decimalToFloat(2, 8));
    await dataStore.setUint(keys.positionImpactFactorKey(ethUsdMarket.marketToken, false), decimalToFloat(2, 8));
    await dataStore.setUint(keys.positionImpactExponentFactorKey(ethUsdMarket.marketToken), decimalToFloat(2, 0));

    expect(await orderStore.getOrderCount()).eq(0);

    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee: expandDecimals(1, 15),
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, params);

    expect(await orderStore.getOrderCount()).eq(1);
    expect(await positionStore.getAccountPositionCount(user0.address)).eq(0);
    expect(await positionStore.getPositionCount()).eq(0);

    await executeOrder(fixture, {
      gasUsageLabel: "executeOrder",
    });

    expect(await orderStore.getOrderCount()).eq(0);
    expect(await positionStore.getAccountPositionCount(user0.address)).eq(1);
    expect(await positionStore.getPositionCount()).eq(1);

    params.account = user1;

    await handleOrder(fixture, {
      create: params,
      execute: {
        gasUsageLabel: "executeOrder",
      },
    });

    expect(await positionStore.getAccountPositionCount(user1.address)).eq(1);
    expect(await positionStore.getPositionCount()).eq(2);
  });
});
