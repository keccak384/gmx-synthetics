import hre from "hardhat";

import { getMarketTokenAddress } from "../utils/market";
import { bigNumberify, expandDecimals } from "../utils/math";

import { WNT, ExchangeRouter, MintableToken } from "../typechain-types";
import { DepositUtils } from "../typechain-types/contracts/exchange/DepositHandler";

const { ethers } = hre;

async function getValues(): Promise<{
  wnt: WNT;
}> {
  if (hre.network.name === "avalancheFuji") {
    return {
      wnt: await ethers.getContractAt("WNT", "0x1D308089a2D1Ced3f1Ce36B1FcaF815b07217be3"),
    };
  } else if (hre.network.name === "localhost") {
    return {
      wnt: await ethers.getContract("WETH"),
    };
  }

  throw new Error("unsupported network");
}

async function main() {
  const marketFactory = await ethers.getContract("MarketFactory");
  const roleStore = await ethers.getContract("RoleStore");
  const dataStore = await ethers.getContract("DataStore");
  const depositStore = await ethers.getContract("DepositStore");
  const exchangeRouter: ExchangeRouter = await ethers.getContract("ExchangeRouter");
  const router = await ethers.getContract("Router");

  const [wallet] = await ethers.getSigners();

  const { wnt } = await getValues();
  const longTokenAmount = expandDecimals(1, 15);
  const executionFee = expandDecimals(1, 15);

  if ((await wnt.balanceOf(wallet.address)).lt(longTokenAmount.add(executionFee))) {
    console.log("depositing %s WNT", longTokenAmount.toString());
    await wnt.deposit({ value: longTokenAmount.add(executionFee) });
  }

  const wntAllowance = await wnt.allowance(wallet.address, router.address);
  console.log("WNT address %s symbol %s", wnt.address, await wnt.symbol());
  console.log("WNT allowance %s", wntAllowance.toString());
  if (wntAllowance.lt(longTokenAmount.add(executionFee))) {
    console.log("approving WNT");
    await wnt.approve(router.address, bigNumberify(2).pow(256).sub(1));
  }
  console.log("WNT balance %s", await wnt.balanceOf(wallet.address));

  const usdc: MintableToken = await ethers.getContract("USDC");
  const shortTokenAmount = expandDecimals(1, 6); // 1 USDC
  const usdcAllowance = await usdc.allowance(wallet.address, router.address);
  console.log("USDC address %s", usdc.address);
  console.log("USDC allowance %s", usdcAllowance.toString());
  if (usdcAllowance.lt(shortTokenAmount)) {
    console.log("approving USDC");
    await usdc.approve(router.address, bigNumberify(2).pow(256).sub(1));
  }
  console.log("USDC balance %s", await usdc.balanceOf(wallet.address));

  const wntUsdMarketAddress = await getMarketTokenAddress(
    wnt.address,
    wnt.address,
    usdc.address,
    marketFactory.address,
    roleStore.address,
    dataStore.address
  );
  console.log("market %s", wntUsdMarketAddress);

  const params: DepositUtils.CreateDepositParamsStruct = {
    receiver: wallet.address,
    callbackContract: ethers.constants.AddressZero,
    market: wntUsdMarketAddress,
    minMarketTokens: 0,
    shouldUnwrapNativeToken: false,
    executionFee: executionFee,
    callbackGasLimit: 0,
  };
  console.log("exchange router %s", exchangeRouter.address);
  console.log("deposit store %s", depositStore.address);
  console.log("creating deposit %s", JSON.stringify(params));

  const multicallArgs = [
    exchangeRouter.interface.encodeFunctionData("sendWnt", [depositStore.address, longTokenAmount.add(executionFee)]),
    exchangeRouter.interface.encodeFunctionData("sendTokens", [usdc.address, depositStore.address, shortTokenAmount]),
    exchangeRouter.interface.encodeFunctionData("createDeposit", [params]),
  ];
  console.log("multicall args", multicallArgs);

  const tx = await exchangeRouter.multicall(multicallArgs, {
    value: longTokenAmount.add(executionFee),
    gasLimit: 2500000,
  });

  console.log("transaction sent", tx.hash);
  await tx.wait();
  console.log("receipt received");
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
