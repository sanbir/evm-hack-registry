// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../3rd/radiant/IFeeDistribution.sol";
import {DepositData} from "../DepositData.sol";
import {RedeemData} from "../RedeemData.sol";

abstract contract AbstractVaultV2 is
  Initializable,
  UUPSUpgradeable,
  ERC4626Upgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;
  error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

  address public oneInchAggregatorAddress;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function _initialize(
    IERC20MetadataUpgradeable asset_,
    string memory name_,
    string memory symbol_
  ) public onlyInitializing {
    ERC4626Upgradeable.__ERC4626_init(asset_);
    ERC20Upgradeable.__ERC20_init(name_, symbol_);
    OwnableUpgradeable.__Ownable_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    UUPSUpgradeable.__UUPSUpgradeable_init();
    PausableUpgradeable.__Pausable_init();
  }

  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address) internal override onlyOwner {}

  function updateOneInchAggregatorAddress(
    address oneInchAggregatorAddress_
  ) external onlyOwner {
    require(oneInchAggregatorAddress_ != address(0), "Address cannot be zero");
    oneInchAggregatorAddress = oneInchAggregatorAddress_;
  }

  function totalLockedAssets() public view virtual returns (uint256);

  function totalStakedButWithoutLockedAssets()
    public
    view
    virtual
    returns (uint256);

  function totalUnstakedAssets() public view virtual returns (uint256);

  function totalAssets() public view override returns (uint256) {
    return
      totalLockedAssets() +
      totalStakedButWithoutLockedAssets() +
      totalUnstakedAssets();
  }

  function getClaimableRewards()
    public
    view
    virtual
    returns (IFeeDistribution.RewardData[] memory claimableRewards);

  function deposit(
    uint256 amount,
    DepositData calldata depositData
  ) public virtual nonReentrant whenNotPaused returns (uint256) {
    _prepareForDeposit(amount, depositData.tokenInAfterSwap);
    uint256 shares = _zapIn(amount, depositData);
    return _mintShares(shares, amount);
  }

  function _prepareForDeposit(
    uint256 amount,
    address tokenIn
  ) internal virtual {
    require(amount <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
    SafeERC20.safeTransferFrom(
      IERC20(tokenIn),
      msg.sender,
      address(this),
      amount
    );
  }

  /* solhint-disable no-unused-vars */
  function _zapIn(
    uint256 amount,
    DepositData calldata depositData
  ) internal virtual returns (uint256) {
    revert("_zapIn not implemented");
  }

  /* solhint-enable no-unused-vars */

  function _mintShares(
    uint256 shares,
    uint256 amount
  ) internal virtual returns (uint256) {
    _mint(msg.sender, shares);
    emit Deposit(_msgSender(), msg.sender, amount, shares);
    return shares;
  }

  function redeem(
    uint256 shares,
    RedeemData calldata redeemData
  )
    public
    nonReentrant
    whenNotPaused
    returns (uint256, address, address, bytes calldata)
  {
    // this part was directly copy from ERC4626.sol
    uint256 maxShares = maxRedeem(msg.sender);
    if (shares > maxShares) {
      revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
    }
    _burn(msg.sender, shares);

    return _redeemFrom3rdPartyProtocol(shares, redeemData);
  }

  /* solhint-disable no-unused-vars */
  function claim() public virtual nonReentrant {
    revert("Not implemented");
  }

  /* solhint-enable no-unused-vars */

  function claimRewardsFromVaultToPortfolioVault(
    IFeeDistribution.RewardData[] memory claimableRewards
  ) public virtual {
    for (uint256 i = 0; i < claimableRewards.length; i++) {
      SafeERC20.safeTransfer(
        IERC20(claimableRewards[i].token),
        msg.sender,
        claimableRewards[i].amount
      );
    }
  }

  /* solhint-disable no-unused-vars */
  function _redeemFrom3rdPartyProtocol(
    uint256 shares,
    RedeemData calldata redeemData
  ) internal virtual returns (uint256, address, address, bytes calldata) {
    revert("not implemented");
  }

  /* solhint-enable no-unused-vars */

  // TODO(david): should remove this block once UUPS works smoothly
  function rescueFunds(
    address tokenAddress,
    uint256 amount
  ) external onlyOwner {
    require(tokenAddress != address(0), "Invalid token address");
    SafeERC20.safeTransfer(IERC20(tokenAddress), owner(), amount);
  }

  function rescueETH(uint256 amount) external onlyOwner {
    payable(owner()).transfer(amount);
  }

  function rescueFundsWithHexData(
    address payable destination,
    uint256 amount,
    bytes memory hexData
  ) external onlyOwner {
    require(destination != address(0), "Invalid destination address");
    require(address(this).balance >= amount, "Insufficient balance");
    // slither-disable-next-line low-level-calls
    // solhint-disable-next-line avoid-low-level-calls
    (bool success, ) = destination.call(hexData);
    require(success, "Fund transfer failed");
  }
  // TODO(david): should remove this block once UUPS works smoothly
}
