import { expect } from "chai";

import { deployFixture } from "../../utils/fixture";
import { expandDecimals, decimalToFloat } from "../../utils/math";
import { printGasUsage } from "../../utils/gas";
import { handleDeposit } from "../../utils/deposit";
import { OrderType, getOrderCount, getOrderKeys, createOrder } from "../../utils/order";

describe("Exchange.CancelOrder", () => {
  const { provider } = ethers;

  let fixture;
  let user0, user1;
  let reader, dataStore, exchangeRouter, ethUsdMarket, wnt;
  let executionFee;

  beforeEach(async () => {
    fixture = await deployFixture();
    ({ user0, user1 } = fixture.accounts);
    ({ reader, dataStore, exchangeRouter, ethUsdMarket, wnt } = fixture.contracts);
    ({ executionFee } = fixture.props);

    await handleDeposit(fixture, {
      create: {
        market: ethUsdMarket,
        longTokenAmount: expandDecimals(1000, 18),
      },
    });
  });

  it("cancelOrder", async () => {
    expect(await getOrderCount(dataStore)).eq(0);
    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [ethUsdMarket.marketToken],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      triggerPrice: expandDecimals(5000, 12),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee,
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.LimitIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, params);

    expect(await getOrderCount(dataStore)).eq(1);

    const block = await provider.getBlock();

    const orderKeys = await getOrderKeys(dataStore, 0, 1);
    const order = await reader.getOrder(dataStore.address, orderKeys[0]);

    expect(order.addresses.account).eq(user0.address);
    expect(order.addresses.market).eq(ethUsdMarket.marketToken);
    expect(order.addresses.initialCollateralToken).eq(wnt.address);
    expect(order.addresses.swapPath).eql([ethUsdMarket.marketToken]);
    expect(order.numbers.orderType).eq(OrderType.LimitIncrease);
    expect(order.numbers.sizeDeltaUsd).eq(decimalToFloat(200 * 1000));
    expect(order.numbers.initialCollateralDeltaAmount).eq(expandDecimals(10, 18));
    expect(order.numbers.acceptablePrice).eq(expandDecimals(5001, 12));
    expect(order.numbers.triggerPrice).eq(expandDecimals(5000, 12));
    expect(order.numbers.executionFee).eq(expandDecimals(1, 15));
    expect(order.numbers.minOutputAmount).eq(expandDecimals(50000, 6));
    expect(order.numbers.updatedAtBlock).eq(block.number);
    expect(order.flags.isLong).eq(true);
    expect(order.flags.shouldUnwrapNativeToken).eq(false);

    await expect(exchangeRouter.connect(user1).cancelOrder(orderKeys[0])).to.be.revertedWith(
      "ExchangeRouter: forbidden"
    );

    expect(await getOrderCount(dataStore)).eq(1);

    const txn = await exchangeRouter.connect(user0).cancelOrder(orderKeys[0]);

    await printGasUsage(provider, txn, "cancelOrder");
    expect(await getOrderCount(dataStore)).eq(0);
  });
});
