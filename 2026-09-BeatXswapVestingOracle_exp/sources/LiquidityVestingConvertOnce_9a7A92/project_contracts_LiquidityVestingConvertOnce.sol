// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// =============================================================
//                      1. INTERFACES (Uniswap V3)
// =============================================================

interface INonfungiblePositionManager {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; uint256 deadline; }
    struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
}

interface IUniswapV3Pool { 
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint32 feeProtocol, bool unlocked);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
}

// =============================================================
//                      2. CONTRACT START
// =============================================================

contract LiquidityVestingConvertOnce is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------
    //                      CONSTANTS & CONFIG
    // ---------------------------------------------------------
    
    IERC20 public constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955); 
    IERC20 public constant BTX  = IERC20(0xAa242a47F4cC074E59cbC7D65309B1F21202AaA3); 
    
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364);
    
    address public constant TARGET_POOL = 0xA5Db84d7BCcb799fb31bd3c417D04d5bC29Da96D;
    
    uint256 public fixedDepositUSDT = 200000000000000000;
    uint256 public vestingDuration = 15552000;

    int24 public constant TICK_RANGE_WIDTH = 6000; 

    address public treasuryWallet = 0xaA2EA785744b123B1e8a1679c8E7aB9B255AAD94;

    // ---------------------------------------------------------
    //                      STRUCTS
    // ---------------------------------------------------------

    struct VestingInfo {
        uint256 id; 
        address user; 
        uint256 depositUSDT; 
        uint256 treasuryAmount;
        uint256 liquidityUSDT;
        uint256 liquidityBTX;
        uint256 totalVestingAmount;
        uint256 vestingPerSecond;
        uint256 tokenId;
        uint128 liquidity;
        uint256 startTime; 
        uint256 endTime; 
        uint256 claimedVestingAmount;
        bool withdrawn;
    }

    // 유저 통계 (단일 참여이므로 누적 == 현재 상태)
    struct UserStats {
        uint256 totalDepositUSDT;    
        uint256 totalTreasuryUSDT;   
        uint256 totalLiquidityUSDT;  
        uint256 totalLiquidityBTX;   
        uint256 totalExpectedVestingAmount; 
        uint256 totalClaimedVestingAmount;  
        uint256 totalWithdrawnLiquidityUSDT; 
        uint256 totalWithdrawnLiquidityBTX;  
    }

    struct GlobalStats {
        uint256 totalDepositedUSDT;
        uint256 totalTreasuryUSDT;
        uint256 totalLiquidityUSDT;
        uint256 totalLiquidityBTX;
        uint256 totalClaimedVestingAmount;
        uint256 totalWithdrawnUSDT;
        uint256 totalWithdrawnBTX;
        uint256 totalVestingCount;
    }

    // ---------------------------------------------------------
    //                      STORAGE
    // ---------------------------------------------------------

    VestingInfo[] public vestingRecords;
    
    // [변경 2] 1인 1계좌를 위한 매핑
    mapping(address => bool) public hasDeposited; // 참여 여부 확인
    mapping(address => uint256) public userVestingId; // 유저의 유일한 Vesting ID 저장
    mapping(address => UserStats) public userStats;
    GlobalStats public globalStats;

    // ---------------------------------------------------------
    //                      EVENTS
    // ---------------------------------------------------------
    
    event ConvertInitiated(uint256 indexed id, address indexed user, uint256 totalUsdt, uint256 treasuryAmount);
    event LiquidityProvisioned(uint256 indexed id, uint256 indexed tokenId, uint256 usdtForLP, uint256 totalVestingAmount, uint256 vestingPerSecond);
    event VestingClaimed(uint256 indexed id, address indexed user, uint256 vestingAmount);
    event LiquidityWithdrawn(uint256 indexed id, address indexed user, uint256 amount0, uint256 amount1);
    
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FixedDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event VestingDurationUpdated(uint256 oldDuration, uint256 newDuration);
    
    error AlreadyDeposited();
    error InvalidDepositAmount();
    error NoDepositFound();
    error InsufficientReserveBTX();
    error InsufficientRewardBalance();
    error NotVestingOwner();
    error StillLocked();
    error AlreadyWithdrawn();
    error InvalidAddress();

    constructor() Ownable(msg.sender) {}

    // =============================================================
    //                      3. ADMIN FUNCTIONS
    // =============================================================

    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert InvalidAddress();
        emit TreasuryUpdated(treasuryWallet, _newTreasury);
        treasuryWallet = _newTreasury;
    }

    function setFixedDeposit(uint256 _newAmount) external onlyOwner {
        emit FixedDepositUpdated(fixedDepositUSDT, _newAmount);
        fixedDepositUSDT = _newAmount;
    }

    function setVestingDuration(uint256 _newDuration) external onlyOwner {
        require(_newDuration > 0, "Duration must be > 0");
        emit VestingDurationUpdated(vestingDuration, _newDuration);
        vestingDuration = _newDuration;
    }

    function recoverToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function setPause(bool _state) external onlyOwner {
        _state ? _pause() : _unpause();
    }

    function fundBTX(uint256 amount) external {
        BTX.safeTransferFrom(msg.sender, address(this), amount);
    }

    // =============================================================
    //                      4. MAIN LOGIC (DEPOSIT)
    // =============================================================

    function deposit(uint256 usdtAmount) external nonReentrant whenNotPaused {
        if (hasDeposited[msg.sender]) revert AlreadyDeposited();
        if (usdtAmount != fixedDepositUSDT) revert InvalidDepositAmount();

        USDT.safeTransferFrom(msg.sender, address(this), usdtAmount);

        uint256 toTreasury = (usdtAmount * 75) / 100; 
        uint256 toLP = usdtAmount - toTreasury; 

        USDT.safeTransfer(treasuryWallet, toTreasury);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _executeMint(toLP);

        if (amount0 < toLP) {
            uint256 dust = toLP - amount0;
            if (dust > 0) {
                USDT.safeTransfer(msg.sender, dust);
            }
        }

        uint256 calculatedVestingAmount = Math.mulDiv(amount1, 2196, 1000);
        uint256 vestingRate = calculatedVestingAmount / vestingDuration;

        uint256 newId = vestingRecords.length;
        uint256 startTime = block.timestamp;
        
        vestingRecords.push(VestingInfo({
            id: newId, 
            user: msg.sender, 
            depositUSDT: usdtAmount, 
            treasuryAmount: toTreasury, 
            liquidityUSDT: amount0, 
            liquidityBTX: amount1, 
            totalVestingAmount: calculatedVestingAmount,
            vestingPerSecond: vestingRate,
            tokenId: tokenId, 
            liquidity: liquidity, 
            startTime: startTime, 
            endTime: startTime + vestingDuration, 
            claimedVestingAmount: 0, 
            withdrawn: false
        }));

        hasDeposited[msg.sender] = true;
        userVestingId[msg.sender] = newId;

        _updateStatsOnDeposit(msg.sender, usdtAmount, toTreasury, amount0, amount1, calculatedVestingAmount);

        emit ConvertInitiated(newId, msg.sender, usdtAmount, toTreasury);
        emit LiquidityProvisioned(newId, tokenId, amount0, calculatedVestingAmount, vestingRate); 
    }

    // =============================================================
    //                      5. MAIN LOGIC (WITHDRAW & CLAIM)
    // =============================================================

    // [변경] 파라미터(vestingId) 제거 -> 알아서 찾음
    function withdraw() external nonReentrant {
        if (!hasDeposited[msg.sender]) revert NoDepositFound();
        
        uint256 id = userVestingId[msg.sender];
        VestingInfo storage info = vestingRecords[id];
        
        if (info.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < info.endTime) revert StillLocked();


        uint256 pending = _calculateClaimable(info);
        if (pending > 0) { 
            info.claimedVestingAmount += pending;
            if (BTX.balanceOf(address(this)) < pending) revert InsufficientRewardBalance();
            BTX.safeTransfer(info.user, pending);
            
            userStats[msg.sender].totalClaimedVestingAmount += pending;
            globalStats.totalClaimedVestingAmount += pending;
            
            emit VestingClaimed(info.id, info.user, pending);
        }

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = 
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: info.tokenId,
                liquidity: info.liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });
        POSITION_MANAGER.decreaseLiquidity(decreaseParams);
        
        INonfungiblePositionManager.CollectParams memory collectParams = 
            INonfungiblePositionManager.CollectParams({
                tokenId: info.tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (uint256 collected0, uint256 collected1) = POSITION_MANAGER.collect(collectParams);
        
        POSITION_MANAGER.burn(info.tokenId);
        
        info.withdrawn = true; 
        info.liquidity = 0; 
        info.tokenId = 0; 

        _updateStatsOnWithdraw(msg.sender, collected0, collected1);

        emit LiquidityWithdrawn(id, msg.sender, collected0, collected1);
    }

    function claim() external nonReentrant {
        if (!hasDeposited[msg.sender]) revert NoDepositFound();
        
        uint256 id = userVestingId[msg.sender];
        VestingInfo storage info = vestingRecords[id];
        
        if (info.withdrawn) revert AlreadyWithdrawn();

        uint256 pending = _calculateClaimable(info);
        if (pending > 0) {
            info.claimedVestingAmount += pending;
            if (BTX.balanceOf(address(this)) < pending) revert InsufficientRewardBalance();
            BTX.safeTransfer(info.user, pending);
            
            userStats[msg.sender].totalClaimedVestingAmount += pending;
            globalStats.totalClaimedVestingAmount += pending;
            
            emit VestingClaimed(info.id, info.user, pending);
        }
    }

    // =============================================================
    //                      6. INTERNAL HELPERS
    // =============================================================

    function _executeMint(uint256 usdtAmountToMint) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        uint256 requiredBTX = _calculateQuote(usdtAmountToMint);
        if (BTX.balanceOf(address(this)) < requiredBTX) revert InsufficientReserveBTX();

        USDT.forceApprove(address(POSITION_MANAGER), type(uint256).max);
        BTX.forceApprove(address(POSITION_MANAGER), type(uint256).max);

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(TARGET_POOL).slot0();
        int24 tickSpacing = IUniswapV3Pool(TARGET_POOL).tickSpacing();
        int24 tickLower = (currentTick - TICK_RANGE_WIDTH) / tickSpacing * tickSpacing;
        int24 tickUpper = (currentTick + TICK_RANGE_WIDTH) / tickSpacing * tickSpacing;

        if (tickLower == tickUpper) {
            tickLower -= tickSpacing;
            tickUpper += tickSpacing;
        }

        uint256 amount0Min = (usdtAmountToMint * 97) / 100;
        uint256 amount1Min = (requiredBTX * 97) / 100;

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: address(USDT), token1: address(BTX), fee: IUniswapV3Pool(TARGET_POOL).fee(), tickLower: tickLower, tickUpper: tickUpper, amount0Desired: usdtAmountToMint, amount1Desired: requiredBTX, amount0Min: amount0Min, amount1Min: amount1Min, recipient: address(this), deadline: block.timestamp
        });
        
        return POSITION_MANAGER.mint(mintParams);
    }

    function _calculateQuote(uint256 usdtAmountIn) internal view returns (uint256 btxAmountOut) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(TARGET_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        address token0 = IUniswapV3Pool(TARGET_POOL).token0();
        
         if (token0 == address(USDT)) {
            btxAmountOut = Math.mulDiv(usdtAmountIn, ratioX192, 1 << 192);
        } else {
            btxAmountOut = Math.mulDiv(usdtAmountIn, 1 << 192, ratioX192);
        }
    }

    function _calculateClaimable(VestingInfo memory info) internal view returns (uint256) {
        if (info.claimedVestingAmount >= info.totalVestingAmount) return 0;

        uint256 currentTime = block.timestamp;
        uint256 vestedAmount;

        if (currentTime >= info.endTime) {
            vestedAmount = info.totalVestingAmount;
        } else {
            uint256 timePassed = currentTime - info.startTime;
            uint256 duration = info.endTime - info.startTime;
            vestedAmount = Math.mulDiv(info.totalVestingAmount, timePassed, duration);
        }

        if (vestedAmount > info.claimedVestingAmount) {
            return vestedAmount - info.claimedVestingAmount;
        }
        return 0;
    }

    function _updateStatsOnDeposit(address user, uint256 depositAmt, uint256 treasuryAmt, uint256 liqUSDT, uint256 liqBTX, uint256 vestingAmount) internal {
        UserStats storage stats = userStats[user];
        stats.totalDepositUSDT += depositAmt;
        stats.totalTreasuryUSDT += treasuryAmt;
        stats.totalLiquidityUSDT += liqUSDT;
        stats.totalLiquidityBTX += liqBTX;
        stats.totalExpectedVestingAmount += vestingAmount;

        globalStats.totalDepositedUSDT += depositAmt;
        globalStats.totalTreasuryUSDT += treasuryAmt;
        globalStats.totalLiquidityUSDT += liqUSDT;
        globalStats.totalLiquidityBTX += liqBTX;
        globalStats.totalVestingCount += 1;
    }

    function _updateStatsOnWithdraw(address user, uint256 col0, uint256 col1) internal {
        UserStats storage stats = userStats[user];
        stats.totalWithdrawnLiquidityUSDT += col0;
        stats.totalWithdrawnLiquidityBTX += col1;

        globalStats.totalWithdrawnUSDT += col0;
        globalStats.totalWithdrawnBTX += col1;
    }

    // =============================================================
    //                      7. VIEW FUNCTIONS (DASHBOARD)
    // =============================================================

    function getContractDashboard() external view returns (GlobalStats memory stats, uint256 currentContractUSDT, uint256 currentContractBTX) {
        stats = globalStats;
        currentContractUSDT = USDT.balanceOf(address(this));
        currentContractBTX = BTX.balanceOf(address(this));
    }

    function getUserDashboard(address user) external view returns (UserStats memory stats, uint256 currentClaimableTotal, bool isDeposited, uint256 remainingTime) {
        stats = userStats[user];
        isDeposited = hasDeposited[user];
        
        if (isDeposited) {
            uint256 id = userVestingId[user];
            VestingInfo memory info = vestingRecords[id];
            
            if (!info.withdrawn) {
                currentClaimableTotal = _calculateClaimable(info);
                if (block.timestamp < info.endTime) {
                    remainingTime = info.endTime - block.timestamp;
                } else {
                    remainingTime = 0;
                }
            }
        }
    }

    function getMyVestingInfo(address user) external view returns (VestingInfo memory) {
        if (!hasDeposited[user]) {
            VestingInfo memory empty; return empty;
        }
        return vestingRecords[userVestingId[user]];
    }
}