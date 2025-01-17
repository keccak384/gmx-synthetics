import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getMarketTokenAddress } from "../utils/market";
import * as keys from "../utils/keys";
import { setUintIfDifferent } from "../utils/dataStore";

const func = async ({ deployments, getNamedAccounts, gmx, ethers }: HardhatRuntimeEnvironment) => {
  const { execute, get, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const tokens = await gmx.getTokens();
  const markets = await gmx.getMarkets();

  const marketFactory = await get("MarketFactory");
  const roleStore = await get("RoleStore");
  const dataStore = await get("DataStore");

  for (const marketConfig of markets) {
    const [indexToken, longToken, shortToken] = marketConfig.tokens.map((symbol) => tokens[symbol].address);

    const marketToken = getMarketTokenAddress(
      indexToken,
      longToken,
      shortToken,
      marketFactory.address,
      roleStore.address,
      dataStore.address
    );
    const code = await ethers.provider.getCode(marketToken);
    if (code !== "0x") {
      log("market %s already exists at %s", marketConfig.tokens.join(":"), marketToken);
      continue;
    }

    log("creating market %s", marketConfig.tokens.join(":"));
    await execute("MarketFactory", { from: deployer, log: true }, "createMarket", indexToken, longToken, shortToken);
  }

  async function setReserveFactor(marketToken: symbol, isLong: boolean, reserveFactor: number) {
    const key = keys.reserveFactorKey(marketToken, isLong);
    await setUintIfDifferent(
      key,
      reserveFactor,
      `reserve factor ${marketToken.toString()} ${isLong ? "long" : "short"}`
    );
  }

  async function setMinCollateralFactor(marketToken: symbol, minCollateralFactor: number) {
    const key = keys.minCollateralFactorKey(marketToken);
    await setUintIfDifferent(key, minCollateralFactor, `min collateral factor ${marketToken.toString()}`);
  }

  async function setMaxPoolAmount(marketToken: symbol, token: string, maxPoolAmount: number) {
    const key = keys.maxPoolAmountKey(marketToken, token);
    await setUintIfDifferent(key, maxPoolAmount, `max pool amount ${marketToken.toString()} ${token.toString()}`);
  }

  async function setMaxOpenInterest(marketToken: symbol, isLong: boolean, maxOpenInterest: number) {
    const key = keys.maxOpenInterestKey(marketToken, isLong);
    await setUintIfDifferent(
      key,
      maxOpenInterest,
      `max open interest ${marketToken.toString()} ${isLong ? "long" : "short"}`
    );
  }

  async function setMaxPnlFactor(marketToken: symbol, isLong: boolean, maxPnlFactor: number) {
    const key = keys.maxPnlFactorKey(marketToken, isLong);
    await setUintIfDifferent(
      key,
      maxPnlFactor,
      `max pnl factor ${marketToken.toString()} ${isLong ? "long" : "short"}`
    );
  }

  async function setMaxPnlFactorForWithdrawals(marketToken: symbol, isLong: boolean, maxPnlFactor: number) {
    const key = keys.maxPnlFactorForWithdrawalsKey(marketToken, isLong);
    await setUintIfDifferent(
      key,
      maxPnlFactor,
      `max pnl factor for withdrawals ${marketToken.toString()} ${isLong ? "long" : "short"}`
    );
  }

  for (const marketConfig of markets) {
    const [indexToken, longToken, shortToken] = marketConfig.tokens.map((symbol: string) => tokens[symbol].address);

    const marketToken = getMarketTokenAddress(
      indexToken,
      longToken,
      shortToken,
      marketFactory.address,
      roleStore.address,
      dataStore.address
    );

    await setMinCollateralFactor(marketToken, marketConfig.minCollateralFactor);

    await setMaxPoolAmount(marketToken, longToken, marketConfig.maxLongTokenPoolAmount);
    await setMaxPoolAmount(marketToken, shortToken, marketConfig.maxShortTokenPoolAmount);

    await setMaxOpenInterest(marketToken, true, marketConfig.maxOpenInterestForLongs);
    await setMaxOpenInterest(marketToken, false, marketConfig.maxOpenInterestForShorts);

    await setReserveFactor(marketToken, true, marketConfig.reserveFactorLongs);
    await setReserveFactor(marketToken, false, marketConfig.reserveFactorShorts);

    await setMaxPnlFactor(marketToken, true, marketConfig.maxPnlFactorLongs);
    await setMaxPnlFactor(marketToken, false, marketConfig.maxPnlFactorShorts);

    await setMaxPnlFactorForWithdrawals(marketToken, true, marketConfig.maxPnlFactorForWithdrawalsLongs);
    await setMaxPnlFactorForWithdrawals(marketToken, false, marketConfig.maxPnlFactorForWithdrawalsShorts);

    for (const name of [
      "positionFeeFactor",
      "positionImpactExponentFactor",
      "swapFeeFactor",
      "swapImpactExponentFactor",
    ]) {
      if (marketConfig[name]) {
        const value = marketConfig[name];
        const key = keys[`${name}Key`](marketToken);
        await setUintIfDifferent(key, value, `${name} for ${marketToken.toString()}`);
      }
    }

    if (marketConfig.positivePositionImpactFactor) {
      const key = keys.positionImpactFactorKey(marketToken, true);
      await setUintIfDifferent(
        key,
        marketConfig.positivePositionImpactFactor,
        `positive position impact factor for ${marketToken.toString()}`
      );
    }
    if (marketConfig.negativePositionImpactFactor) {
      const key = keys.positionImpactFactorKey(marketToken, false);
      await setUintIfDifferent(
        key,
        marketConfig.negativePositionImpactFactor,
        `negative position impact factor for ${marketToken.toString()}`
      );
    }

    if (marketConfig.positiveMaxPositionImpactFactor) {
      const key = keys.maxPositionImpactFactorKey(marketToken, true);
      await setUintIfDifferent(
        key,
        marketConfig.positiveMaxPositionImpactFactor,
        `positive max position impact factor for ${marketToken.toString()}`
      );
    }
    if (marketConfig.negativeMaxPositionImpactFactor) {
      const key = keys.maxPositionImpactFactorKey(marketToken, false);
      await setUintIfDifferent(
        key,
        marketConfig.negativeMaxPositionImpactFactor,
        `negative max position impact factor for ${marketToken.toString()}`
      );
    }

    if (marketConfig.positiveSwapImpactFactor) {
      const key = keys.swapImpactFactorKey(marketToken, true);
      await setUintIfDifferent(
        key,
        marketConfig.positiveSwapImpactFactor,
        `positive swap impact factor for ${marketToken.toString()}`
      );
    }
    if (marketConfig.negativeSwapImpactFactor) {
      const key = keys.swapImpactFactorKey(marketToken, false);
      await setUintIfDifferent(
        key,
        marketConfig.negativeSwapImpactFactor,
        `negative swap impact factor for ${marketToken.toString()}`
      );
    }
  }
};

func.skip = async ({ gmx, network }) => {
  // skip if no markets configured
  const markets = await gmx.getMarkets();
  if (!markets || markets.length === 0) {
    console.warn("no markets configured for network %s", network.name);
    return true;
  }
  return false;
};
func.tags = ["Markets"];
func.dependencies = ["MarketFactory", "Tokens", "DataStore"];
export default func;
