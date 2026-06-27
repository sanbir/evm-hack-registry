// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../../interfaces/common/ISolidlyRouter.sol";
import "../../interfaces/common/ISolidlyPair.sol";
import "../../interfaces/common/IRewardPool.sol";
import "../../interfaces/common/IERC20Extended.sol";
import "../../common/StratManagerUpgradeable.sol";
import "../../common/DynamicFeeManager.sol";
import "hardhat/console.sol";

interface ISwapRouter {
  struct ExactInputParams {
    bytes path;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
  }

  function exactInput(ExactInputParams calldata params) external returns (uint256);
}

contract StrategyCommonSolidlyHybridPoolLP is StratManagerUpgradeable, DynamicFeeManager {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  // Tokens used
  address public native;
  address public output;
  address public want;
  address public lpToken0;
  address public lpToken1;
  address public dystRouter2;

  // Third party contracts
  address public rewardPool;

  bool public stable;
  bool public harvestOnDeposit;
  uint256 public lastHarvest;
  bytes public outputToNativePath;
  bytes public outputToLp0Path;
  bytes public outputToLp1Path;

  address[] public rewards;
  uint256 public feeOnProfits;

  event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
  event Deposit(uint256 tvl);
  event Withdraw(uint256 tvl);
  event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);

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
  ) public virtual initializer {
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
    outputToNativePath = _outputToNativePath;
    outputToLp0Path = _outputToLp0Path;
    outputToLp1Path = _outputToLp1Path;
    _giveAllowances();
  }

  // puts the funds to work
  function deposit() public whenNotPaused {
    uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));

    if (wantBal > 0) {
      IRewardPool(rewardPool).deposit(wantBal);
      emit Deposit(balanceOf());
    }
  }

  function withdraw(uint256 _amount) external {
    require(msg.sender == vault, "!vault");

    uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));

    if (wantBal < _amount) {
      IRewardPool(rewardPool).withdraw(_amount - wantBal);
      wantBal = IERC20Upgradeable(want).balanceOf(address(this));
    }

    if (wantBal > _amount) {
      wantBal = _amount;
    }

    if (tx.origin != owner() && !paused()) {
      uint256 withdrawalFeeAmount = (wantBal * withdrawalFee) / WITHDRAWAL_MAX;
      wantBal = wantBal - withdrawalFeeAmount;
    }

    IERC20Upgradeable(want).safeTransfer(vault, wantBal);

    emit Withdraw(balanceOf());
  }

  function beforeDeposit() external virtual override {
    if (harvestOnDeposit) {
      require(msg.sender == vault, "!vault");
      _harvest(tx.origin);
    }
  }

  function harvest() external virtual {
    _harvest(tx.origin);
  }

  function harvest(address callFeeRecipient) external virtual {
    _harvest(callFeeRecipient);
  }

  // compounds earnings and charges performance fee
  function _harvest(address callFeeRecipient) internal whenNotPaused {
    IRewardPool(rewardPool).getReward();
    uint256 outputBal = IERC20Upgradeable(output).balanceOf(address(this));
    console.log("output: %s", output);
    console.log("outputBal: %s", outputBal);
    if (outputBal > 0) {
      chargeFees(callFeeRecipient);
      addLiquidity();
      uint256 wantHarvested = balanceOfWant();
      deposit();

      lastHarvest = block.timestamp;
      emit StratHarvest(msg.sender, wantHarvested, balanceOf());
    }
  }

  /**
   * @dev Charges performance fees.
   * @param callFeeRecipient The address to receive the call fee.
   */
  function chargeFees(address callFeeRecipient) internal {
    uint256 generalFeeOnProfits = (IERC20Upgradeable(output).balanceOf(address(this)) * feeOnProfits) / 1000;

    uint256 generalFeeAmount;
    if (generalFeeOnProfits > 0) {
      if (output != native) {
        uint256 nativeBeforeSwap = IERC20Upgradeable(native).balanceOf(address(this));

        ISwapRouter.ExactInputParams memory param = ISwapRouter.ExactInputParams(
          outputToNativePath,
          address(this),
          block.timestamp + 10000,
          generalFeeOnProfits,
          0
        );

        console.log("param.amountIn", param.amountIn);
        console.log("dystRouter", dystRouter);

        ISwapRouter(dystRouter).exactInput(param);
        generalFeeAmount = IERC20Upgradeable(native).balanceOf(address(this)) - nativeBeforeSwap;
      } else {
        generalFeeAmount = generalFeeOnProfits;
      }
    }

    uint256 callFeeAmount = (generalFeeAmount * callFee) / MAX_FEE;
    if (callFeeAmount > 0) {
      IERC20Upgradeable(native).safeTransfer(callFeeRecipient, callFeeAmount);
    }

    // Calculating the Fee to be distributed
    uint256 feeAmount1 = (generalFeeAmount * fee1) / MAX_FEE;
    uint256 feeAmount2 = (generalFeeAmount * fee2) / MAX_FEE;
    uint256 strategistFeeAmount = (generalFeeAmount * strategistFee) / MAX_FEE;

    // Transfer fees to recipients
    if (feeAmount1 > 0) {
      IERC20Upgradeable(native).safeTransfer(feeRecipient1, feeAmount1);
    }
    if (feeAmount2 > 0) {
      IERC20Upgradeable(native).safeTransfer(feeRecipient2, feeAmount2);
    }
    if (strategistFeeAmount > 0) {
      IERC20Upgradeable(native).safeTransfer(strategist, strategistFeeAmount);
    }
  }

  // Adds liquidity to AMM and gets more LP tokens.
  function addLiquidity() internal virtual {
    uint256 outputBal = IERC20Upgradeable(output).balanceOf(address(this));
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

    uint256 lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
    uint256 lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));
    ISolidlyRouter(dystRouter2).addLiquidity(
      lpToken0,
      lpToken1,
      stable,
      lp0Bal,
      lp1Bal,
      1,
      1,
      address(this),
      block.timestamp
    );
  }

  // calculate the total underlaying 'want' held by the strat.
  function balanceOf() public view returns (uint256) {
    return balanceOfWant() + balanceOfPool();
  }

  // it calculates how much 'want' this contract holds.
  function balanceOfWant() public view returns (uint256) {
    return IERC20Upgradeable(want).balanceOf(address(this));
  }

  // it calculates how much 'want' the strategy has working in the farm.
  function balanceOfPool() public view returns (uint256) {
    return IRewardPool(rewardPool).balanceOf(address(this));
  }

  // returns rewards unharvested
  function rewardsAvailable() public view returns (uint256) {
    return IRewardPool(rewardPool).earned(address(this));
  }

  function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
    harvestOnDeposit = _harvestOnDeposit;

    if (harvestOnDeposit) {
      setWithdrawalFee(0);
    } else {
      setWithdrawalFee(10);
    }
  }

  function setFeeOnProfits(uint256 _feeOnProfits) external onlyManager {
    feeOnProfits = _feeOnProfits;
  }

  // called as part of strat migration. Sends all the available funds back to the vault.
  function retireStrat() external {
    require(msg.sender == vault, "!vault");

    IRewardPool(rewardPool).withdraw(balanceOfPool());

    uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
    IERC20Upgradeable(want).transfer(vault, wantBal);
  }

  // pauses deposits and withdraws all funds from third party systems.
  function panic() public onlyManager {
    pause();
    IRewardPool(rewardPool).withdraw(balanceOfPool());
  }

  function pause() public onlyManager {
    _pause();

    _removeAllowances();
  }

  function unpause() external onlyManager {
    _unpause();

    _giveAllowances();

    deposit();
  }

  function _giveAllowances() internal virtual {
    IERC20Upgradeable(want).safeApprove(rewardPool, type(uint256).max);
    IERC20Upgradeable(output).safeApprove(dystRouter, type(uint256).max);

    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, type(uint256).max);

    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, type(uint256).max);
  }

  function _removeAllowances() internal virtual {
    IERC20Upgradeable(want).safeApprove(rewardPool, 0);
    IERC20Upgradeable(output).safeApprove(dystRouter, 0);

    IERC20Upgradeable(lpToken0).safeApprove(dystRouter, 0);
    IERC20Upgradeable(lpToken1).safeApprove(dystRouter, 0);
  }
}
