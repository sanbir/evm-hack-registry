// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../libraries/GiddyLibraryV3.sol";
import "../interfaces/giddy/IGiddyDefiAdapter.sol";
import "../strategies/GiddyBaseStrategyV3.sol";

/**
 * @title GiddyVaultV3
 * @notice Implementation of Giddy V3 vault - the main entry point for users and backend
 * @dev Vault contract handles deposits, withdrawals, and user interactions
 *      Strategy contract handles the actual yield farming logic
 *      Uses user shares system (non-transferrable) instead of ERC20 receipt tokens
 *      Vault token is the single token the vault is denominated in (e.g., USDC, LP token)
 *      Implements standard yield farming pattern with Giddy-specific modifications
 */
contract GiddyVaultV3 is OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  using ECDSA for bytes32;

    /**
     * @dev Struct for authorized deposit/withdrawal operations
     * @param signature EIP-712 signature for authorization
     * @param nonce Unique nonce to prevent replay attacks
     * @param deadline Timestamp after which the authorization expires
     * @param amount Amount of tokens (deposits) or shares (on withdrawals)
     * @param vaultSwaps Array of swap operations for vault deposits/withdrawals
     * @param compoundSwaps Array of swap operations for compounding rewards
     */
  struct VaultAuth {
    bytes signature;
    bytes32 nonce;
    uint256 deadline;
    uint256 amount;
    SwapInfo[] vaultSwaps;
    SwapInfo[] compoundSwaps;
  }

  struct TransactionFeeInfo {
    address token;
    uint256 balance;
  }

    // ============ Errors ============

  error InvalidAuthorization(string reason);
  error NonceAlreadyUsed(bytes32 nonce);
  error AuthorizationExpired(uint256 deadline);
  error InsufficientShares(uint256 requested, uint256 available);
  error SwapLengthMismatch(uint256 expected, uint256 actual);
  error InvalidSwapToken(address expected, address actual);

    // ============ State Variables ============

  string public name;
  address public strategy;
  mapping(address => uint256) public userShares;
  uint256 public totalShares;

  uint256 private constant SHARES_MULTIPLIER = 1e10;
  address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  bytes32 public DOMAIN_SEPARATOR;
  bytes32 public constant VAULTAUTH_TYPEHASH = keccak256("VaultAuth(bytes32 nonce,uint256 deadline,uint256 amount,bytes[] data)");
  
  mapping(bytes32 => bool) public nonceUsed;
  
  // ============ Events ============

  event Deposit(address indexed from, address depositToken, uint256 depositAmount, uint256 sharesMinted);
  event Withdraw(address indexed from, address withdrawToken, uint256 withdrawAmount,uint256 sharesBurned);
  event Yield(uint256 vaultTokens, uint256 totalShares, uint256 growthIndex, uint256 cumulativeYield);
  event StrategyUpgraded(address indexed oldStrategy, address indexed newStrategy);
  event TransactionFeesCollected(address indexed recipient, uint256[] amounts);

  // ============ Initializer ============

  function initialize(string calldata _name, address _strategy) external initializer {
    name = _name;
    strategy = _strategy;
      
    __Ownable_init(_msgSender());
    __ReentrancyGuard_init();
      

    DOMAIN_SEPARATOR = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes(_name)),
        keccak256(bytes("1.0")),
        block.chainid,
        address(this)
      )
    );
  }

  // ============ Getters ============

  function getVaultToken() public view returns (address token) {
    return GiddyBaseStrategyV3(strategy).vaultToken();
  }

  function getBaseTokens() public view returns (address[] memory) {
    return GiddyBaseStrategyV3(strategy).getBaseTokens();
  }

  function getBaseAmounts(uint256 vaultTokens) public view returns (uint256[] memory) {
    return GiddyBaseStrategyV3(strategy).getBaseAmounts(vaultTokens);
  }

  function getBaseRatios() external view returns (uint256[] memory) {
    return GiddyBaseStrategyV3(strategy).getBaseRatios();
  }

  function totalBalance() public view returns (uint256 vaultTokens) {
    return GiddyBaseStrategyV3(strategy).balanceOf();
  }

  function getVaultTokensPerShare() public view returns (uint256 vaultTokens) {
      return sharesToValue(10 ** (IERC20Metadata(getVaultToken()).decimals()+10));
  }

  function balanceOfVaultTokens(address user) public view returns (uint256 vaultTokens) {
      uint256 shares = userShares[user];
      if (shares == 0) return 0;
      return sharesToValue(shares);
  }

  function sharesToValue(uint256 shares) public view returns (uint256 vaultTokens) {
    if (totalShares == 0) {
      return 10 ** IERC20Metadata(getVaultToken()).decimals(); // Default 1:1 ratio when no shares exist
    }
    return (shares * totalBalance()) / totalShares;
  }

  function valueToShares(uint256 vaultTokens) public view returns (uint256 shares) {
    if (totalShares == 0) {
      return vaultTokens * SHARES_MULTIPLIER; // First deposit case
    }
    if (totalBalance() == 0) {
      return 0;
    }
    return (vaultTokens * totalShares) / totalBalance();
  }

  function getWithdrawAmounts(uint256 shares) external view returns (uint256[] memory) {
    return getBaseAmounts(sharesToValue(shares));
  }

  function rewardTokens() external view returns (address[] memory tokens) {
    return GiddyBaseStrategyV3(payable(strategy)).getRewardTokens();
  }

  function getRewardInfo() external view returns (GiddyBaseStrategyV3.RewardTokenInfo[] memory info) {
    return GiddyBaseStrategyV3(strategy).getRewardInfo();
  }

    /**
   * @dev Returns type(uint256).max for unlimited, 0 if full, or actual remaining amount, denominated in vault tokens
   */
  function getRemainingCapacity() external view returns (uint256 remaining) {
    return GiddyBaseStrategyV3(strategy).getRemainingCapacity();
  }

  function getTvl() external view returns (uint256 tvl) {
    return GiddyBaseStrategyV3(strategy).getTvl();
  }

  function isAuthorizedSigner(address _signer) public view returns (bool) {
    return GiddyBaseStrategyV3(strategy).isAuthorizedSigner(_signer);
  }

  /**
   * @notice Get the strategy's growth index tracking yield from all sources
   * @return index Growth index (starts at 1e18 = 100%)
   * @dev Growth index increases as yield is recorded, similar to how yield-bearing tokens work
   *      This reflects the actual value growth that users experience
   */
  function getGrowthIndex() public view returns (uint256 index) {
    return GiddyBaseStrategyV3(strategy).strategyGrowthIndex();
  }

  /**
   * @notice Get the cumulative yield earned by the vault in vault tokens
   * @return yield Total yield earned from all sources (after performance fees)
   * @dev This tracks all yield earned over the lifetime of the vault that users actually received
   */
  function getCumulativeYield() public view returns (uint256 yield) {
    return GiddyBaseStrategyV3(strategy).cumulativeYield();
  }

  /**
   * @notice Get pending yield that hasn't been recorded yet
   * @return pending Total pending yield in vault tokens (before performance fees)
   * @dev This is a view function that shows yield waiting to be recorded
   */
  function getPendingYield() public view returns (uint256 pending) {
    return GiddyBaseStrategyV3(strategy).getPendingYield();
  }

    function getPendingTransactionFees() external view returns (TransactionFeeInfo[] memory fees) {
    address[] memory baseTokens = getBaseTokens();
    fees = new TransactionFeeInfo[](baseTokens.length);

    for (uint256 i = 0; i < baseTokens.length; ++i) {
      fees[i] = TransactionFeeInfo({
        token: baseTokens[i],
        balance: IERC20(baseTokens[i]).balanceOf(address(this))
      });
    }
  }

  // ============ Deposit/Withdraw Functions ============

  function deposit(VaultAuth calldata auth) external payable nonReentrant {
    _validateAuthorization(auth);
    _executeDeposit(_msgSender(), auth);
  }

  function proxyDeposit(VaultAuth calldata auth, address depositor) external payable nonReentrant {
    require(depositor != address(0), "Invalid depositor");
    _validateAuthorization(auth);
    _executeDeposit(depositor, auth);
  }

  function withdraw(VaultAuth calldata auth) external nonReentrant {
    _validateAuthorization(auth);

    address sender = _msgSender();
    address[] memory baseTokens = getBaseTokens();

    _compound(auth.compoundSwaps);
    _recordYield();

    if (userShares[_msgSender()] < auth.amount) {
      revert InsufficientShares(auth.amount, userShares[sender]);
    }
    if (baseTokens.length != auth.vaultSwaps.length) {
      revert SwapLengthMismatch(baseTokens.length, auth.vaultSwaps.length);
    }

    // Calculate vault tokens to withdraw based on shares being withdrawn then burn shares
    uint256 vaultTokensToWithdraw = (auth.amount * totalBalance()) / totalShares;
    userShares[sender] -= auth.amount;
    totalShares -= auth.amount;

    // Withdraws base tokens from the strategy contract and then swaps them to the withdraw token
    // Note: executeSwap handles fromToken == toToken case (transfers directly without swap)
    GiddyBaseStrategyV3(strategy).withdraw(vaultTokensToWithdraw);
    uint256 totalWithdrawn = 0;
    for (uint256 i = 0; i < baseTokens.length; ++i) {
      SwapInfo calldata swap = auth.vaultSwaps[i];
      if (swap.amount > 0) {
        if (baseTokens[i] != swap.fromToken) {
          revert InvalidSwapToken(baseTokens[i], swap.fromToken);
        }
        totalWithdrawn += GiddyLibraryV3.executeSwap(swap, address(this), sender);
      }
    }
    emit Withdraw(sender, auth.vaultSwaps[0].toToken, totalWithdrawn, auth.amount);
  }

  /**
   * @notice Standalone compound function that can be called to compound rewards
   * @param auth VaultAuth struct containing signature and compound swap data
   * @dev This function allows compounding to be called independently without a deposit/withdrawal
   *      Swaps reward tokens to base tokens, then deposits them back into the strategy
   *      Requires valid authorization signature from owner
   */
  function compound(VaultAuth calldata auth) external nonReentrant {
    _validateAuthorization(auth);
    _compound(auth.compoundSwaps);
    _recordYield();
  }

  function emergencyWithdraw(uint amount) external onlyOwner returns(uint256[] memory amounts) {
    address[] memory baseTokens = getBaseTokens();
    amounts = new uint256[](baseTokens.length);
    for (uint256 i = 0; i < baseTokens.length; ++i) {
      amounts[i] = IERC20(baseTokens[i]).balanceOf(address(this));
    }
    GiddyBaseStrategyV3(strategy).withdraw(amount);
    for (uint256 i = 0; i < baseTokens.length; ++i) {
      amounts[i] = IERC20(baseTokens[i]).balanceOf(address(this)) -  amounts[i];
    }
    GiddyBaseStrategyV3(strategy).pause();
  }

  function rescueToken(address token, address to, uint256 amount) external onlyOwner {
    require(token != getVaultToken(), "Cannot rescue vault token");
    require(to != address(0), "Invalid recipient");
    IERC20(token).safeTransfer(to, amount);
  }

  /**
   * @notice Upgrade to a new strategy, migrating all funds atomically
   * @param newStrategy Address of the new strategy to migrate to
   * @dev Uses existing withdraw/deposit flow to migrate funds between strategies
   */
  function upgradeStrategy(address newStrategy) external onlyOwner nonReentrant {
    require(newStrategy != address(0), "Invalid strategy address");
    require(newStrategy != strategy, "Same strategy");
    require(address(this) == GiddyBaseStrategyV3(newStrategy).vault(), "Strategy not valid for vault");
    require(getVaultToken() == GiddyBaseStrategyV3(newStrategy).vaultToken(), "Different vault token");
    
    address oldStrategy = strategy;
    uint256 balanceToMigrate = totalBalance();
    
    if (balanceToMigrate > 0) {
      // Withdraw all funds from old strategy
      // This withdraws from DeFi protocol, converts to base tokens via adapter, and sends to vault
      GiddyBaseStrategyV3(oldStrategy).withdraw(balanceToMigrate);
      
      // Get base tokens that were transferred to vault
      address[] memory baseTokens = getBaseTokens();
      uint256[] memory amounts = new uint256[](baseTokens.length);
      
      for (uint256 i = 0; i < baseTokens.length; ++i) {
        amounts[i] = IERC20(baseTokens[i]).balanceOf(address(this));
        if (amounts[i] > 0) {
          IERC20(baseTokens[i]).safeTransfer(newStrategy, amounts[i]);
        }
      }
      
      strategy = newStrategy;
      GiddyBaseStrategyV3(newStrategy).deposit(amounts, true);
    } else {
      strategy = newStrategy;
    }
    
    emit StrategyUpgraded(oldStrategy, newStrategy);
  }

  /**
   * @notice Collect accumulated transaction fees and send to recipient
   * @param recipient Address to receive the transaction fees
   * @dev Only callable by owner. Transfers all base token balances from vault to recipient
   */
  function collectTransactionFees(address recipient) external onlyOwner {

    address[] memory baseTokens = getBaseTokens();
    uint256[] memory amounts = new uint256[](baseTokens.length);

    for (uint256 i = 0; i < baseTokens.length; ++i) {
      uint256 balance = IERC20(baseTokens[i]).balanceOf(address(this));
      if (balance > 0) {
        amounts[i] = balance;
        IERC20(baseTokens[i]).safeTransfer(recipient, balance);
      }
    }

    emit TransactionFeesCollected(recipient, amounts);
  }

  // ============ Internal Functions ============

  function _executeDeposit(address depositor, VaultAuth calldata auth) private {
    address sender = _msgSender();
    address[] memory baseTokens = getBaseTokens();
    address depositToken = auth.vaultSwaps[0].fromToken;
  
    _compound(auth.compoundSwaps);
    _recordYield();
    uint256 beforeDeposit = totalBalance();
    
    if (baseTokens.length != auth.vaultSwaps.length) {
      revert SwapLengthMismatch(baseTokens.length, auth.vaultSwaps.length);
    }
    if (!_isNativeToken(depositToken)) {
      IERC20(depositToken).safeTransferFrom(sender, address(this), auth.amount);        
    }

    // Execute swaps and transfer base tokens to strategy
    // Note: executeSwap handles fromToken == toToken case (transfers directly without swap)
    uint256[] memory amounts = new uint256[](baseTokens.length);
    for (uint256 i = 0; i < baseTokens.length; ++i) {
      SwapInfo calldata swap = auth.vaultSwaps[i];
      if (swap.amount > 0) {
        if (baseTokens[i] != swap.toToken) {
          revert InvalidSwapToken(baseTokens[i], swap.fromToken);
        }
        amounts[i] = GiddyLibraryV3.executeSwap(swap, address(this), strategy);
      }
    }
    
    // Calculate shares to mint based on actual value added to the strategy
    GiddyBaseStrategyV3(strategy).deposit(amounts, true);
    uint256 actualValueAdded = totalBalance() - beforeDeposit;

    uint256 newShares = totalShares == 0 ? actualValueAdded * SHARES_MULTIPLIER : actualValueAdded * totalShares / beforeDeposit;
    userShares[depositor] += newShares;
    totalShares += newShares;
    emit Deposit(depositor, depositToken, auth.amount, newShares);
  }

  function _recordYield() internal {
    GiddyBaseStrategyV3(strategy).recordYield();
    emit Yield(totalBalance(), totalShares, getGrowthIndex(), getCumulativeYield());
  }

  function _compound(SwapInfo[] calldata compoundSwaps) internal {
    if (compoundSwaps.length > 0) {
      uint256[] memory rewardAmounts = GiddyBaseStrategyV3(strategy).swapRewardTokens(compoundSwaps);
      GiddyBaseStrategyV3(strategy).deposit(rewardAmounts, false);
    }
  }

  function _isNativeToken(address token) internal pure returns (bool) {
    return token == NATIVE_TOKEN || token == address(0);
  }

  function _validateAuthorization(VaultAuth calldata auth) internal {

      if (block.timestamp > auth.deadline) {
          revert AuthorizationExpired(auth.deadline);
      }
      if (nonceUsed[auth.nonce]) {
          revert NonceAlreadyUsed(auth.nonce);
      }
      
      bytes memory dataArray;
      for (uint256 i = 0; i < auth.vaultSwaps.length; ++i) {
          dataArray = abi.encodePacked(dataArray, keccak256(auth.vaultSwaps[i].data));
      }
      for (uint256 i = 0; i < auth.compoundSwaps.length; ++i) {
          dataArray = abi.encodePacked(dataArray, keccak256(auth.compoundSwaps[i].data));
      }
      
      bytes memory data = abi.encodePacked(
          VAULTAUTH_TYPEHASH,
          abi.encode(
              auth.nonce,
              auth.deadline,
              auth.amount,
              keccak256(dataArray)
          )
      );
      // Create EIP-712 hash
      bytes32 digest = keccak256(
          abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(data))
      );
      
      // Recover signer and verify against authorized signer
      address signer = digest.recover(auth.signature);
      if (!isAuthorizedSigner(signer)) {
          revert InvalidAuthorization("Invalid signature");
      }
      
      nonceUsed[auth.nonce] = true;
  }

  function version() external pure returns (string memory) {
      return "3.0";
  }
}
