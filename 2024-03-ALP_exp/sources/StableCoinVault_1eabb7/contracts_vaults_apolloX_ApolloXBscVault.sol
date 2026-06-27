// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../3rd/apolloX/IApolloX.sol";
import "../../interfaces/AbstractVaultV2.sol";
import "../../3rd/radiant/IFeeDistribution.sol";
import "./ApolloXDepositData.sol";
import "./ApolloXRedeemData.sol";
import {DepositData} from "../../DepositData.sol";
import {RedeemData} from "../../RedeemData.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";

contract ApolloXBscVault is AbstractVaultV2 {
  using SafeERC20 for IERC20;

  IApolloX public apolloX;
  IERC20 public ALP;
  IERC20 public constant APX =
    IERC20(0x78F5d389F5CDCcFc41594aBaB4B0Ed02F31398b3);
  uint256 public ratioAfterPerformanceFee;
  uint256 public denominator;

  function initialize(
    IERC20MetadataUpgradeable asset_,
    string memory name_,
    string memory symbol_,
    uint256 ratioAfterPerformanceFee_,
    uint256 denominator_
  ) public initializer {
    AbstractVaultV2._initialize(asset_, name_, symbol_);

    apolloX = IApolloX(0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0);
    ALP = IERC20(0x4E47057f45adF24ba41375a175dA0357cB3480E5);
    ratioAfterPerformanceFee = ratioAfterPerformanceFee_;
    denominator = denominator_;
  }

  function updateApolloXAddr(address newAddr) public onlyOwner {
    require(newAddr != address(0), "Address cannot be zero");
    apolloX = IApolloX(newAddr);
  }

  function updateAlpAddr(address newAddr) public onlyOwner {
    require(newAddr != address(0), "Address cannot be zero");
    ALP = IERC20(newAddr);
  }

  function updatePerformanceFeeMetaData(
    uint256 ratioAfterPerformanceFee_,
    uint256 denominator_
  ) public onlyOwner {
    require(denominator_ != 0, "denominator cannot be zero");
    require(
      ratioAfterPerformanceFee_ <= denominator_,
      "ratioAfterPerformanceFee_ cannot be greater than denominator_"
    );
    ratioAfterPerformanceFee = ratioAfterPerformanceFee_;
    denominator = denominator_;
  }

  function totalLockedAssets() public pure override returns (uint256) {
    return 0;
  }

  function totalStakedButWithoutLockedAssets()
    public
    view
    override
    returns (uint256)
  {
    return apolloX.stakeOf(address(this));
  }

  function totalUnstakedAssets() public view override returns (uint256) {
    return IERC20(asset()).balanceOf(address(this));
  }

  function claim() public override nonReentrant whenNotPaused {
    IFeeDistribution.RewardData[]
      memory claimableRewards = getClaimableRewards();
    if (claimableRewards.length != 0) {
      apolloX.claimAllReward();
      super.claimRewardsFromVaultToPortfolioVault(claimableRewards);
    }
  }

  function getClaimableRewards()
    public
    view
    override
    returns (IFeeDistribution.RewardData[] memory rewards)
  {
    // pro rata: user's share divided by total shares, is the ratio of the reward
    uint256 portfolioSharesInThisVault = balanceOf(msg.sender);
    uint256 totalVaultShares = totalSupply();
    // slither-disable-next-line incorrect-equality
    if (portfolioSharesInThisVault == 0 || totalVaultShares == 0) {
      return new IFeeDistribution.RewardData[](0);
    }
    rewards = new IFeeDistribution.RewardData[](1);

    uint256 claimableRewardsBelongsToThisPortfolio = Math.mulDiv(
      apolloX.pendingApx(address(this)),
      portfolioSharesInThisVault,
      totalVaultShares
    );
    rewards[0] = IFeeDistribution.RewardData({
      token: address(APX),
      amount: _calClaimableAmountAfterPerformanceFee(
        claimableRewardsBelongsToThisPortfolio
      )
    });
    return rewards;
  }

  function getPerformanceFeeRateMetaData()
    public
    view
    returns (uint256, uint256)
  {
    return (ratioAfterPerformanceFee, denominator);
  }

  function _zapIn(
    uint256 amount,
    DepositData calldata depositData
  ) internal override returns (uint256) {
    IERC20 tokenInERC20 = IERC20(depositData.apolloXDepositData.tokenIn);
    SafeERC20.forceApprove(tokenInERC20, address(apolloX), amount);
    SafeERC20.forceApprove(ALP, address(apolloX), amount);
    uint256 originalStakeOf = apolloX.stakeOf(address(this));
    apolloX.mintAlp(
      address(tokenInERC20),
      amount,
      depositData.apolloXDepositData.minALP,
      true
    );
    uint256 currentStakeOf = apolloX.stakeOf(address(this));
    uint256 mintedALPAmount = currentStakeOf - originalStakeOf;
    return mintedALPAmount;
  }

  function _calClaimableAmountAfterPerformanceFee(
    uint256 claimableRewardsBelongsToThisPortfolio
  ) internal view returns (uint256) {
    (
      uint256 ratioAfterPerformanceFee,
      uint256 denominator
    ) = getPerformanceFeeRateMetaData();
    return
      Math.mulDiv(
        claimableRewardsBelongsToThisPortfolio,
        ratioAfterPerformanceFee,
        denominator
      );
  }

  function _redeemFrom3rdPartyProtocol(
    uint256 shares,
    RedeemData calldata redeemData
  ) internal override returns (uint256, address, address, bytes calldata) {
    apolloX.unStake(shares);
    SafeERC20.forceApprove(ALP, address(apolloX), shares);
    uint256 originalTokenOutBalance = IERC20(
      redeemData.apolloXRedeemData.alpTokenOut
    ).balanceOf(address(this));
    apolloX.burnAlp(
      redeemData.apolloXRedeemData.alpTokenOut,
      shares,
      redeemData.apolloXRedeemData.minOut,
      address(this)
    );
    uint256 currentTokenOutBalance = IERC20(
      redeemData.apolloXRedeemData.alpTokenOut
    ).balanceOf(address(this));
    uint256 redeemAmount = currentTokenOutBalance - originalTokenOutBalance;
    SafeERC20.safeTransfer(
      IERC20(redeemData.apolloXRedeemData.alpTokenOut),
      msg.sender,
      redeemAmount
    );
    return (
      redeemAmount,
      redeemData.apolloXRedeemData.alpTokenOut,
      redeemData.apolloXRedeemData.tokenOut,
      redeemData.apolloXRedeemData.aggregatorData
    );
  }
}
