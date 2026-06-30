// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "../libraries/GiddyLibraryV3.sol";
import "../infra/GiddyAdapterManager.sol";
import "../infra/GiddyStrategyFactory.sol";
import "../interfaces/giddy/IGiddyFeeConfig.sol";

/**
 * @title GiddyBaseStrategyV3
 * @notice Base strategy contract for Giddy V3 vaults
 * @dev Implements centralized strategy management pattern for efficient configuration
 *      Provides common functionality for all V3 strategies
 *      Child contracts override specific yield farming logic (_deposit, _withdraw, etc.)
 *      Designed to work with BeaconProxy pattern for upgradeability
 */
abstract contract GiddyBaseStrategyV3 is PausableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  // ============ Structs ============

  struct StrategyInitParams {
    string name;
    address vaultToken;
    address factory;
    address vault;
    address[] rewardTokens;
  }

  struct RewardTokenInfo {
    address token;
    uint256 balance; // held + claimable
  }

  // ============ Errors ============

  error UnauthorizedCaller(address caller);
  error StrategyPaused();
  error NotManager();
  error AdapterZapFailed();
  error InsufficientCapacity(uint256 required, uint256 available);

  // ============ Events ============

  event YieldStats(uint256 vaultYield, uint256 adatperYield);
  event BalanceStats(uint256 balanceOne, uint256 balanceTwo);
  event PerformanceFees(uint256 amount);

  // ============ State Variables ============

  address public vault;
  address public vaultToken;
  address public factory;
  uint256 public lastProcessYield;
  string public name;

  // Yield Tracking
  address[] public rewardTokens;
  uint256 public lastVaultTokenBalance;
  uint256 public lastVaultTokenGrowthIndex; // deprecated
  mapping(address => uint256) public lastBaseTokensGrowthIndexes;
  uint256 public performanceFees;
  uint256 public strategyGrowthIndex;
  uint256 public cumulativeYield;

  // ============ Modifiers ============

  modifier onlyVault() {
    if (_msgSender() != vault) {
      revert UnauthorizedCaller(msg.sender);
    }
    _;
  }

  modifier ifNotPaused() {
    if (paused()) revert StrategyPaused();
    if (
      GiddyStrategyFactory(factory).globalPause() ||
      GiddyStrategyFactory(factory).strategyPause(stratName())
    ) revert StrategyPaused();
    _;
  }

  modifier onlyManager() {
    _checkManager();
    _;
  }

  // ============ Initialization ============

  /**
   * @notice Initialize the base strategy
   * @param params Struct containing all strategy initialization parameters
   * @dev This function should be called by child contracts in their initialize function
   */
  function __BaseStrategy_init(StrategyInitParams memory params) internal onlyInitializing {
    require(params.vaultToken != address(0), "Invalid vaultToken address");
    require(params.factory != address(0), "Invalid factory address");
    require(params.vault != address(0), "Invalid vault address");

    __Pausable_init();
    __ReentrancyGuard_init();

    vaultToken = params.vaultToken;
    factory = params.factory;
    vault = params.vault;
    name = params.name;
    strategyGrowthIndex = 1e18;

    // Add reward tokens
    for (uint256 i = 0; i < params.rewardTokens.length; ++i) {
      addRewardToken(params.rewardTokens[i]);
    }

    // Initialize growth index tracking
    _recordAdapterYield(vaultToken, 0);
  }

  // Legacy migration helper for yield tracking state
  function initializeYieldConversion() external onlyManager() {
    lastBaseTokensGrowthIndexes[vaultToken] = lastVaultTokenBalance;
  }

  // ============ Core Operations ============

  /**
   * @notice Deposit vault tokens into the strategy
   * @param amounts Array of base token amounts to zap into vault tokens
   * @param userDeposit If true, this is a user deposit and will revert on insufficient capacity
   *                    If false, this is a compound and will deposit what fits
   * @dev User deposits (userDeposit=true) require full capacity and revert otherwise
   *      Compounds (userDeposit=false) deposit what fits and hold remainder in contract
   */
  function deposit(uint256[] calldata amounts, bool userDeposit) external onlyVault ifNotPaused nonReentrant {
    address adapter = address(_getTokenAdapter(vaultToken));
    uint256 depositedVaultTokens;

    if (adapter != address(0)) {
      (bool success, bytes memory result) = adapter.delegatecall(
        abi.encodeWithSignature("zapIn(address,uint256[])", vaultToken, amounts)
      );
      if (!success) {
        revert AdapterZapFailed();
      }
      if (result.length != 32) {
        revert AdapterZapFailed();
      }
      depositedVaultTokens = abi.decode(result, (uint256));
    } else {
      // No adapter means the base token is the vault token itself.
      // AdapterManager guarantees a single-base-token path in this case.
      require(amounts.length == 1, "Invalid amounts length");
      depositedVaultTokens = amounts[0];
    }
    
    uint256 totalVaultTokenAmount = _balanceInContract();
    if (totalVaultTokenAmount == 0) return;

    uint256 remainingCapacity = getRemainingCapacity();
    
    // User deposits should be validated and accounted using only newly received funds.
    // Previously queued balance (from prior compounds/capacity limits) must not block user deposits
    // or be added again to lastVaultTokenBalance.
    if (userDeposit) {
      if (depositedVaultTokens > remainingCapacity) {
        revert InsufficientCapacity(depositedVaultTokens, remainingCapacity);
      }
      _deposit(depositedVaultTokens);
      lastVaultTokenBalance += depositedVaultTokens;
      return;
    }

    // Compound path: deposit as much as fits and leave the rest in contract.
    if (totalVaultTokenAmount <= remainingCapacity) {
      _deposit(totalVaultTokenAmount);
      return;
    }
    if (remainingCapacity > 0) {
      _deposit(remainingCapacity);
    }
    // If remainingCapacity is 0, tokens stay in contract (still counted in balanceOf())
  }

  function withdraw(uint256 amount) external onlyVault ifNotPaused nonReentrant {
    uint256 stakedBalance = _balanceInDefiStrategy();
    uint256 toWithdraw = amount > stakedBalance ? stakedBalance : amount;
    _withdraw(toWithdraw);

    _zapOut(amount, vault);
    if (amount >= lastVaultTokenBalance) {
      lastVaultTokenBalance = 0;
    } else {
      lastVaultTokenBalance -= amount;
    }
  }

  // ============ Yield Processing ============

  /**
   * @notice Get pending yield that hasn't been recorded yet
   * @return Total pending yield in vault tokens (before performance fees)
   * @dev This is a view function that calculates yield without recording it
   */
  function getPendingYield() public view returns (uint256) {
    uint256 currentBalance = balanceOf();
    uint256 quantityYield = currentBalance > lastVaultTokenBalance ? currentBalance - lastVaultTokenBalance : 0;
    uint256 valueYield = _calculateAdapterYield(vaultToken, lastVaultTokenBalance);
    return quantityYield + valueYield;
  }

  /**
   * @notice Record yield and accumulate performance fees
   * @dev Only callable by the vault contract
   */
  function recordYield() external onlyVault {    
    IGiddyFeeConfig feeConfig = _giddyFeeConfig();
   
    // 1) Calculate yield from vault token quantity increasing
    uint256 previousBalance = lastVaultTokenBalance;
    uint256 currentBalance = balanceOf();
    uint256 vaultYield = 0;
    if (currentBalance > previousBalance) {
      vaultYield = currentBalance - previousBalance;
    }
    emit BalanceStats(currentBalance, previousBalance);
    
    uint256 adatperYield = _recordAdapterYield(vaultToken, previousBalance);
    
    // TOTAL YIELD since last processing (no reward yield calculation, no compounding)
    uint256 totalYield = vaultYield + adatperYield;
    emit YieldStats(vaultYield, adatperYield);
        
    // Calculate and accumulate PERFORMANCE FEES
    uint256 feeRate = feeConfig.getPerformanceFee(address(this), stratName());
    uint256 performanceFeeAmount = (totalYield * feeRate) / 10000;
    uint256 updatedBalance = previousBalance > currentBalance ? previousBalance : currentBalance;

    if (performanceFeeAmount > 0) {
      // Add fee to performanceFees instead of transferring immediately
      performanceFees += performanceFeeAmount;
      totalYield -= performanceFeeAmount; // Update total yield to reflect fee deduction

      // Performance fees are an outflow from strategy TVL and should not expand
      // the gap between tracked balance and current balance.
      if (updatedBalance > performanceFeeAmount) {
        updatedBalance -= performanceFeeAmount;
      } else {
        updatedBalance = 0;
      }
    }
    
    // Update CUMULATIVE YIELD earned and STRATEGY GROWTH INDEX (after fees)
    if (previousBalance > 0 && totalYield > 0) {
      cumulativeYield += totalYield;
      // Formula: newIndex = currentIndex * (1 + yield/balance)
      strategyGrowthIndex = strategyGrowthIndex + (strategyGrowthIndex * totalYield) / previousBalance;
    }

    lastVaultTokenBalance = updatedBalance;
    lastProcessYield = block.timestamp;
  }

  /**
   * @notice Collect accumulated performance fees and send to fee recipient
   */
  function collectFees() external onlyManager {
    if (performanceFees == 0) return;

    // Pull funds from the strategy, then zaps out and sends to fee wallet
    _withdraw(performanceFees);
    _zapOut(performanceFees, _giddyFeeRecipient());
    emit PerformanceFees(performanceFees);
    performanceFees = 0; // Reset performance fees to 0
  }

  /**
   * @notice Swap reward tokens to base tokens using provided swap data
   * @param swaps Array of swap operations to convert reward tokens to base tokens
   * @dev Called by vault to swap claimed rewards to base tokens
   *      Claims rewards, swaps to base tokens, only swaps tokens that meet threshold
   *      Swaps are structured as: for each reward token, swaps to each base token
   * @return amounts Array of base token amounts received from swaps
   */
  function swapRewardTokens(SwapInfo[] calldata swaps) external onlyVault ifNotPaused nonReentrant returns (uint256[] memory amounts){
    _claimAllRewards();

    address[] memory baseTokens = _adapterManager().getBaseTokens(vaultToken);
    uint256 baseTokensLength = baseTokens.length;
    uint256 swapsLength = swaps.length;
    amounts = new uint256[](baseTokensLength);

    // Execute all configured reward token swaps
    for (uint256 i = 0; i < swapsLength; ++i) {
      SwapInfo calldata swap = swaps[i];
      if (swap.amount == 0) continue;

      uint256 baseTokenIndex = i % baseTokensLength;

      uint256 amountReceived = GiddyLibraryV3.executeSwap(swap, address(this), address(this));
      amounts[baseTokenIndex] += amountReceived;
    }

    return amounts;
  }

  // ============ View Functions (Public) ============

  function isAuthorizedSigner(address _signer) public view returns (bool) {
    return GiddyStrategyFactory(factory).isAuthorizedSigner(_signer);
  }

  function getBaseTokens() external view virtual returns (address[] memory tokens) {
    return _adapterManager().getBaseTokens(vaultToken);
  }

  function getBaseRatios() external view virtual returns (uint256[] memory ratios) {
    return _adapterManager().getBaseRatios(vaultToken);
  }

  function getBaseAmounts(uint256 amount) external view virtual returns (uint256[] memory amounts) {
    return _adapterManager().getBaseAmounts(vaultToken, amount);
  }

  function balanceOf() public view returns (uint256) {
    return _balanceInContract() + _balanceInDefiStrategy() - performanceFees;
  }

  function getRewardTokens() public view returns (address[] memory tokens) {
    return rewardTokens;
  }

  function getRewardInfo() external view virtual returns (RewardTokenInfo[] memory info) {
    info = new RewardTokenInfo[](rewardTokens.length);
    for (uint256 i = 0; i < rewardTokens.length; ++i) {
      address token = rewardTokens[i];
      uint256 heldBalance = IERC20(token).balanceOf(address(this));
      uint256 claimableBalance = _getClaimableBalance(token);
      info[i] = RewardTokenInfo({
        token: token,
        balance: heldBalance + claimableBalance
      });
    }
    return info;
  }

  function getRemainingCapacity() public view virtual returns (uint256 remaining) {
    return type(uint256).max; // Default: unlimited, denominated in vault tokens
  }

  function getTvl() public view virtual returns (uint256 tvl) {
    return balanceOf(); // Default: return balanceOf() for the strategy contract
  }

  function baseVersion() external pure returns (string memory) {
    return "3.0";
  }

  // ============ Management Functions ============

  function panic() external onlyManager {
    pause();
    uint256 balance = _balanceInDefiStrategy();
    if (balance > 0) {
      _withdraw(balance);
    }
  }

  function pause() public onlyManager {
    _pause();
  }

  function unpause() external onlyManager {
    _unpause();
  }

  function rescueToken(
    address token,
    address to,
    uint256 amount
  ) external onlyManager {
    require(token != vaultToken, "Cannot rescue vaultToken");
    require(to != address(0), "Invalid recipient");

    IERC20(token).safeTransfer(to, amount);
  }

  function addRewardToken(address token) public onlyManager {
    require(token != address(0), "Invalid token");
    require(token != vaultToken, "Cannot add vault token");

    rewardTokens.push(token);
  }

  function removeRewardToken(uint256 index) external onlyManager {
    require(index < rewardTokens.length, "Index out of bounds");

    // Swap with last element and pop
    rewardTokens[index] = rewardTokens[rewardTokens.length - 1];
    rewardTokens.pop();
  }

  function resetRewardTokens() external onlyManager {
    // Clear array
    delete rewardTokens;
  }

  function setVault(address newVault) external onlyManager {
    require(newVault != address(0), "Invalid vault address");
    vault = newVault;
  }

  function setYieldTrackingMetrics(
    uint256 _lastVaultTokenBalance,
    uint256 _cumulativeYield,
    uint256 _strategyGrowthIndex,
    uint256 _performanceFees
  ) external onlyManager {
    lastVaultTokenBalance = _lastVaultTokenBalance;
    cumulativeYield = _cumulativeYield;
    strategyGrowthIndex = _strategyGrowthIndex;
    performanceFees = _performanceFees;
  }

  function setBaseTokenGrowthIndex(address token, uint256 index) external onlyManager {
    lastBaseTokensGrowthIndexes[token] = index;
  }

  // ============ Internal Helper Functions ============

  function _balanceInContract() internal view returns (uint256) {
    return IERC20(vaultToken).balanceOf(address(this));
  }

  function _adapterManager() internal view returns (GiddyAdapterManager) {
    return GiddyAdapterManager(GiddyStrategyFactory(factory).adapterManager());
  }

  function _getTokenAdapter(address defiToken) internal view returns (IGiddyDefiAdapter) {
    return IGiddyDefiAdapter(GiddyAdapterManager(GiddyStrategyFactory(factory).adapterManager()).getTokenAdapter(defiToken));
  }

  function _giddyFeeConfig() internal view returns (IGiddyFeeConfig) {
    return IGiddyFeeConfig(GiddyStrategyFactory(factory).feeConfig());
  }

  function _giddyFeeRecipient() internal view returns (address) {
    return _giddyFeeConfig().feeRecipient();
  }

  function _performanceFee() internal view returns (uint256 fee) {
    return _giddyFeeConfig().getPerformanceFee(address(this), stratName());
  }

  function _zapOut(uint256 amount, address recipient) internal {
    address adapter = address(_getTokenAdapter(vaultToken));
    if (adapter != address(0)) {
      (bool success, ) = adapter.delegatecall(
        abi.encodeWithSignature(
          "zapOut(address,uint256,address)",
          vaultToken,
          amount,
          recipient
        )
      );
      if (!success) revert AdapterZapFailed();
    } else {
      IERC20(vaultToken).safeTransfer(recipient, amount);
    }
  }

  function _checkManager() internal view {
    if (!GiddyStrategyFactory(factory).isKeeper(msg.sender))
      revert NotManager();
  }

  /**
   * @notice Calculate adapter yield without updating state (view-only)
   * @param defiToken The DeFi token to calculate yield for
   * @param affectedBalance The balance affected by this calculation
   * @return yield The calculated yield amount
   */
  function _calculateAdapterYield(address defiToken, uint256 affectedBalance) internal view returns (uint256 yield) {
    IGiddyDefiAdapter adapter = _getTokenAdapter(defiToken);
    if (address(adapter) != address(0)) {
      // Calculate yield from defi token
      uint256 currentIndex = adapter.getGrowthIndex(defiToken);
      if (currentIndex > 0) {
        uint256 lastIndex = lastBaseTokensGrowthIndexes[defiToken];
        if (currentIndex > lastIndex && lastIndex > 0) {
          yield = ((currentIndex - lastIndex) * affectedBalance) / lastIndex;
        }
      }
    }
  }

  /**
   * @notice Calculate and record adapter yield, updating state
   * @param defiToken The DeFi token to record yield for
   * @param affectedBalance The balance affected by this calculation
   * @return yield The calculated yield amount
   */
  function _recordAdapterYield(address defiToken, uint256 affectedBalance) internal returns (uint256 yield) {
    IGiddyDefiAdapter adapter = _getTokenAdapter(defiToken);
    if (address(adapter) != address(0)) {
      // Calculate yield from defi token
      uint256 currentIndex = adapter.getGrowthIndex(defiToken);
      if (currentIndex > 0) { // Skips if no adapter is set
        uint256 lastIndex = lastBaseTokensGrowthIndexes[defiToken];
        if (lastIndex == 0) {
          // Initialize the index on first use (no yield calculation since there's no baseline)
          lastBaseTokensGrowthIndexes[defiToken] = currentIndex;
        } else if (currentIndex > lastIndex) {
          // Calculate yield and update index (high-water mark)
          yield = ((currentIndex - lastIndex) * affectedBalance) / lastIndex;
          lastBaseTokensGrowthIndexes[defiToken] = currentIndex; // Only update if current index is more (high-water mark)
        }
      }
    }
  }

  // ============ Abstract Functions for Child Contracts ============

  function _deposit(uint256 amount) internal virtual;

  function _withdraw(uint256 amount) internal virtual;

  function _balanceInDefiStrategy()internal view virtual returns (uint256 vaultTokenBalance) {
    return IERC20(vaultToken).balanceOf(address(this));
  }

  function _getClaimableBalance(address /* token */) internal view virtual returns (uint256 claimable) {
    return 0;
  }

  function _claimAllRewards() internal virtual {}

  function stratName() public view virtual returns (string memory name);

  function version() public pure virtual returns (string memory);
}
