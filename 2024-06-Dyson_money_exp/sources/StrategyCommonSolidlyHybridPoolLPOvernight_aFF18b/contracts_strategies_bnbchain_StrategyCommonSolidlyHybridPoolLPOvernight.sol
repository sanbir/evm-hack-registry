// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./StrategyCommonSolidlyHybridPoolLP.sol";
import "./interfaces/IOvernightExchange.sol";


contract StrategyCommonSolidlyHybridPoolLPOvernight is StrategyCommonSolidlyHybridPoolLP {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  // Tokens used
  address public overnightUsdPlusMinter;
  address public overnightUsdtPlusMinter;
  address public usdPlus;
  address public usdtPlus;

  function initialize(
    address _want,
    address _rewardPool,
    address[] memory _addresses,
    bytes memory _outputToNativePath,
    bytes memory _outputToLp0Path,
    bytes memory _outputToLp1Path,
    address _output,
    address _native,
    address _lpToken0,
    address _lpToken1
  ) public override initializer {
    __Ownable_init_unchained();
    __Pausable_init_unchained();
    __DynamicFeeManager_init();
    want = _want;
    rewardPool = _rewardPool;
    __StratManager_init_unchained(_addresses[0], _addresses[1], _addresses[2], _addresses[3], _addresses[4]);

    stable = ISolidlyPair(want).stable();

    output = _output;
    native = _native;
    lpToken0 = _lpToken0;
    lpToken1 = _lpToken1;

    rewards.push(output);
    feeOnProfits = 40;
    dystRouter2 = _addresses[5];
    overnightUsdPlusMinter = _addresses[6];
    overnightUsdtPlusMinter = _addresses[7];
    usdPlus = IOvernightExchange(overnightUsdPlusMinter).usdPlus();
    usdtPlus = IOvernightExchange(overnightUsdtPlusMinter).usdPlus();
    outputToNativePath = _outputToNativePath;
    outputToLp0Path = _outputToLp0Path;
    outputToLp1Path = _outputToLp1Path;
    _giveAllowances();
  }

  // Adds liquidity to AMM and gets more LP tokens.
  function addLiquidity() internal override {
    uint256 outputBal = IERC20Upgradeable(output).balanceOf(address(this));
    console.log("outputBal", outputBal);
    uint256 lp0Amt = outputBal / 2;
    uint256 lp1Amt = outputBal - lp0Amt;

    if (lpToken0 != output) {
      ISwapRouter.ExactInputParams memory param = ISwapRouter.ExactInputParams(
        outputToLp0Path,
        address(this),
        block.timestamp + 10000,
        lp0Amt,
        0
      );
      ISwapRouter(dystRouter).exactInput(param);
    }

    if (lpToken1 != output) {
      ISwapRouter.ExactInputParams memory param = ISwapRouter.ExactInputParams(
        outputToLp1Path,
        address(this),
        block.timestamp + 10000,
        lp1Amt,
        0
      );
      ISwapRouter(dystRouter).exactInput(param);
    }


    Exchange.MintParams memory params0;
    Exchange.MintParams memory params1;

    params0.asset = lpToken0;
    params0.amount = IERC20Upgradeable(lpToken0).balanceOf(address(this));
    params0.referral = "";


    params1.asset = lpToken1;
    params1.amount = IERC20Upgradeable(lpToken1).balanceOf(address(this));
    params1.referral = "";


    IOvernightExchange(overnightUsdPlusMinter).mint(params0);
    IOvernightExchange(overnightUsdtPlusMinter).mint(params1);
    uint256 lp0Bal = IERC20Upgradeable(usdPlus).balanceOf(address(this));
    uint256 lp1Bal = IERC20Upgradeable(usdtPlus).balanceOf(address(this));
    ISolidlyRouter(dystRouter2).addLiquidity(
      usdPlus,
      usdtPlus,
      stable,
      lp0Bal,
      lp1Bal,
      1,
      1,
      address(this),
      block.timestamp
    );
  }

  function _giveAllowances() internal override {
    IERC20Upgradeable(want).safeApprove(rewardPool, type(uint256).max);
    IERC20Upgradeable(output).safeApprove(dystRouter, type(uint256).max);

    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, type(uint256).max);

    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, type(uint256).max);

    IERC20Upgradeable(usdPlus).safeApprove(dystRouter2, 0);
    IERC20Upgradeable(usdPlus).safeApprove(dystRouter2, type(uint256).max);

    IERC20Upgradeable(usdtPlus).safeApprove(dystRouter2, 0);
    IERC20Upgradeable(usdtPlus).safeApprove(dystRouter2, type(uint256).max);

    IERC20Upgradeable(lpToken0).safeApprove(overnightUsdPlusMinter, 0);
    IERC20Upgradeable(lpToken0).safeApprove(overnightUsdPlusMinter, type(uint256).max);

    IERC20Upgradeable(lpToken1).safeApprove(overnightUsdtPlusMinter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(overnightUsdtPlusMinter, type(uint256).max);
  }

  function _removeAllowances() internal override {
    IERC20Upgradeable(want).safeApprove(rewardPool, 0);
    IERC20Upgradeable(output).safeApprove(dystRouter, 0);

    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken0).safeApprove(overnightUsdPlusMinter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(overnightUsdtPlusMinter, 0);

    IERC20Upgradeable(usdPlus).safeApprove(dystRouter2, 0);
    IERC20Upgradeable(usdtPlus).safeApprove(dystRouter2, 0);
  }
}
