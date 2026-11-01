// SPDX-License-Identifier: Coinleft Public License for BitBay
pragma solidity = 0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getFeeGrowthInside(bytes32 poolId, int24 tickLower, int24 tickUpper) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
    function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) external view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IFeeVault {
    function addShares(address user, uint256 amount) external;
    function removeShares(address user, uint256 amount) external;
    function migrate(address vault) external;
    function setMigrate() external;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

interface ILiquidityPool {
    function syncAMM(address pair) external;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

contract FeeVault {
    IERC20 public immutable DAI;
    IERC20 public immutable USDC;
    address public immutable vault;
    address public minter;
    address public liquiditypool;
    bool public waitToMigrate;
    
    uint256 public totalShares;
    uint256 public accPerShareDAI;
    uint256 public accPerShareUSDC;
    uint256 public lastBalanceDAI;
    uint256 public lastBalanceUSDC;
    uint256 public minAmountOut = 990000000000000000; // 0.99 DAI per USDC (1% slippage)
    uint24 public constant SWAP_FEE = 100; // 0.01% pool (stablecoin pool)
    
    mapping(address => uint256) public shares;
    mapping(address => address) public sendTo;
    mapping(address => uint256) public debtDAI;
    mapping(address => uint256) public debtUSDC;
    mapping(address => bool) public isPair;

    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // V3 Router on Polygon
    
    constructor(address _dai, address _usdc, address _minter) {
        DAI = IERC20(_dai);
        USDC = IERC20(_usdc);
        vault = msg.sender;
        minter = _minter;
        liquiditypool = 0x8c412AE83c219db1654b0913035c9eb7424d9b50;
        isPair[0x37f75363c6552D47106Afb9CFdA8964610207938] = true;  //BAYL/DAI Uniswap
        isPair[0x63Ff2f545E4CbCfeBBdeE27bB5dA56fdEE076524] = true;  //BAYR/DAI Uniswap
        isPair[0x9A3Ec2E1F99cd32E867701ee0031A91e2f139640] = true;  //BAYL/DAI Quickswap
        isPair[0x353C49C5bE1bBf834C35Cd8b1A876b5fa0e4e7CE] = true;  //BAYR/DAI Quickswap
    }
    
    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    function setLiquidityPool(address _pool) external {
        require(msg.sender == minter);
        liquiditypool = _pool;
    }

    function addPair(address _pair, bool status) external {
        require(msg.sender == minter);
        isPair[_pair] = status;
    }

    function setMinAmountOut(uint256 _min) external {
        require(msg.sender == minter);
        require(_min >= 950000000000000000 && _min <= 995000000000000000);
        minAmountOut = _min;
    }
    
    function addShares(address user, uint256 amount) external onlyVault {
        require(!waitToMigrate);
        _update();
        if (sendTo[user] == address(0)) {
            sendTo[user] = user;
        }
        if (shares[user] > 0) {
            _settle(user);
        }
        shares[user] += amount;
        totalShares += amount;
        debtDAI[user] = (shares[user] * accPerShareDAI) / 1e18;
        debtUSDC[user] = (shares[user] * accPerShareUSDC) / 1e18;
        _syncBalance();
    }
    
    function removeShares(address user, uint256 amount) external onlyVault {
        require(!waitToMigrate);
        _update();
        _settle(user);
        shares[user] -= amount;
        totalShares -= amount;
        debtDAI[user] = (shares[user] * accPerShareDAI) / 1e18;
        debtUSDC[user] = (shares[user] * accPerShareUSDC) / 1e18;
        _syncBalance();
    }
    
    function claim() external {
        _update();
        _settle(msg.sender);
        debtDAI[msg.sender] = (shares[msg.sender] * accPerShareDAI) / 1e18;
        debtUSDC[msg.sender] = (shares[msg.sender] * accPerShareUSDC) / 1e18;
        _syncBalance();
    }
    
    function _update() internal {
        uint256 balDAI = DAI.balanceOf(address(this));
        uint256 balUSDC = USDC.balanceOf(address(this));
        if (totalShares > 0) {
            if (balDAI > lastBalanceDAI) {
                accPerShareDAI += ((balDAI - lastBalanceDAI) * 1e18) / totalShares;
            }
            if (balUSDC > lastBalanceUSDC) {
                accPerShareUSDC += ((balUSDC - lastBalanceUSDC) * 1e18) / totalShares;
            }
        }
        lastBalanceDAI = balDAI;
        lastBalanceUSDC = balUSDC;
    }
    
    function _settle(address user) internal {
        uint256 owedDAI = (shares[user] * accPerShareDAI / 1e18) - debtDAI[user];
        uint256 owedUSDC = (shares[user] * accPerShareUSDC / 1e18) - debtUSDC[user];
        if (sendTo[user] == address(0)) {
            sendTo[user] = user;
        }
        address recipient = sendTo[user];
        // If sending to a DAI pair, swap USDC to DAI first
        if (isPair[recipient] && owedUSDC > 0) {
            uint256 daiReceived = _swapUSDCtoDAI(owedUSDC);
            if (daiReceived > 0) {
                owedDAI += daiReceived;
                owedUSDC = 0;
            }
        }
        if (owedDAI > 0) DAI.transfer(recipient, owedDAI);
        if (owedUSDC > 0) {
            if(isPair[recipient]) {
                USDC.transfer(user, owedUSDC);
            } else {
                USDC.transfer(recipient, owedUSDC);
            }
        }
        if(isPair[recipient]) {
            try ILiquidityPool(liquiditypool).syncAMM(recipient) {
            } catch {}
        }
    }
    
    function _syncBalance() internal {
        lastBalanceDAI = DAI.balanceOf(address(this));
        lastBalanceUSDC = USDC.balanceOf(address(this));
    }

    function _swapUSDCtoDAI(uint256 amountIn) internal returns (uint256 amountOut) {
        USDC.approve(address(swapRouter), amountIn);
        try swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(DAI),
                fee: SWAP_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: (amountIn * minAmountOut) / 1e6, // Scale to 18 decimals
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out) {
            amountOut = out;
        } catch {
            amountOut = 0; //Swap failed - just send USDC directly to the user instead
        }
    }
    
    function pendingFees(address user) external view returns (uint256, uint256) {
        if (shares[user] == 0) return (0, 0);
        uint256 tempAccDAI = accPerShareDAI;
        uint256 tempAccUSDC = accPerShareUSDC;
        if (totalShares > 0) {
            uint256 balDAI = DAI.balanceOf(address(this));
            uint256 balUSDC = USDC.balanceOf(address(this));
            
            if (balDAI > lastBalanceDAI) {
                tempAccDAI += ((balDAI - lastBalanceDAI) * 1e18) / totalShares;
            }
            if (balUSDC > lastBalanceUSDC) {
                tempAccUSDC += ((balUSDC - lastBalanceUSDC) * 1e18) / totalShares;
            }
        }
        uint256 daiPending = (shares[user] * tempAccDAI / 1e18) - debtDAI[user];
        uint256 usdcPending = (shares[user] * tempAccUSDC / 1e18) - debtUSDC[user];
        return (daiPending, usdcPending);
    }

    function migrate(address _vault) external onlyVault {
        uint256 balDAI = DAI.balanceOf(address(this));
        uint256 balUSDC = USDC.balanceOf(address(this));
        if (balDAI > 0) DAI.transfer(_vault, balDAI);
        if (balUSDC > 0) USDC.transfer(_vault, balUSDC);
    }
    
    function changeSendTo(address to) external {
        sendTo[msg.sender] = to;
    }

    function setMigrate() external onlyVault {
        waitToMigrate = true;
    }
}

contract UsdcDaiV4Vault is IUnlockCallback {
    IStateView immutable stateView;
    IPoolManager immutable poolManager;

    uint8 internal constant ACTION_DEPOSIT = 0x00;
    uint8 internal constant ACTION_WITHDRAW = 0x01;
    uint8 internal constant ACTION_COLLECT = 0x02;
    uint8 internal constant ACTION_REPOSITION = 0x03;
    uint8 internal constant ACTION_CLEAN_DUST = 0x04;
    uint8 internal constant ACTION_WITHDRAW_DUST = 0x05;
    uint8 public tradeThis = 0;
    uint256 public MIN_PRICE = 0.995e18;
    uint256 public MAX_PRICE = 1.005e18;
    uint256 public MAX_SLIPPAGE_BPS = 20; // .2%

    IERC20 immutable DAI;
    IERC20 immutable USDC;
    IERC20 immutable USDT;
    address public immutable treasury;

    PoolKey poolKey;
    PoolKey daiKey;
    PoolKey usdcKey;
    int24 public RANGE = 1;
    int24 public offset = 1;
    int24 public constant TICK_SPACING = 1;
    uint24 public constant FEE = 50;

    int24 public tickLower;
    int24 public tickUpper;
    int24 public lowTickAdmin;
    int24 public highTickAdmin;
    uint128 public liquidity;
    bytes32 public salt;

    uint256 public totalShares;
    uint256 public lastReposition;
    uint256 public POSITION_TIMELOCK = 3 days; // If the position is moved too much it might cost too much in trading fees
    int128 public commission = 25; //Percentage paid to treasury for stakers to manage the pool and fees
    address public minter;
    address public feeVault;
    bool public lockThis;
    bool public mintThis;
    bool public salvageFees;
    bool private locked;

    mapping(address => uint256) public shares;
    mapping(uint256 => mapping(address => uint256)) public weeklyRewards;

    event Deposited(address indexed user, uint256 daiAmount, uint256 sharesIssued);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 daiOut, uint256 usdcOut);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event Repositioned(int24 newTickLower, int24 newTickUpper, uint128 newLiquidity);
    event DustCleaned(uint256 balance, uint256 dust);

    error Reentrancy();
    error NotPoolManager();
    error ZeroAmount();
    error InsufficientShares();
    error NoPosition();
    error PositionInRange();
    error OutOfRange();
    error UnknownAction();
    error Expired();
    error SlippageExceeded();
    error PriceOutOfBounds();
    error OnlyMinter();
    error MinterLocked();

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address _treasury) {
        address _dai = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
        address _usdc = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
        address _usdt = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
        address _poolManager = 0x67366782805870060151383F4BbFF9daB53e5cD6;
        feeVault = address(new FeeVault(_dai, _usdc, msg.sender));
        DAI = IERC20(_dai);
        USDC = IERC20(_usdc);
        USDT = IERC20(_usdt);
        poolManager = IPoolManager(_poolManager);
        stateView = IStateView(0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a);
        treasury = _treasury;
        (address c0, address c1) = _dai < _usdc ? (_dai, _usdc) : (_usdc, _dai);
        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(0)
        });
        (c0, c1) = _usdt < _usdc ? (_usdt, _usdc) : (_usdc, _usdt);
        usdcKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 8,
            tickSpacing: 1,
            hooks: address(0)
        });
        (c0, c1) = _usdt < _dai ? (_usdt, _dai) : (_dai, _usdt);
        daiKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 20,
            tickSpacing: 1,
            hooks: address(0)
        });
        salt = bytes32(uint256(1));
        IERC20(_dai).approve(_poolManager, type(uint256).max);
        IERC20(_usdc).approve(_poolManager, type(uint256).max);
        IERC20(_usdt).approve(_poolManager, type(uint256).max);
        minter = msg.sender;
    }

    function changeMinter(address newminter) public {
        require(msg.sender == minter, OnlyMinter());
        require(!lockThis, MinterLocked());
        minter = newminter;
    }

    function changeVault(address vault, bool migrate) public {
        require(msg.sender == minter, OnlyMinter());
        require(salvageFees, MinterLocked());
        require(vault != address(0));
        if(migrate) {
            IFeeVault(feeVault).migrate(vault);
        }
        feeVault = vault;
    }

    function changeCommission(int128 _commission) public {
        require(msg.sender == minter, OnlyMinter());
        require(_commission >= 10 && _commission <= 75);
        commission = _commission;
    }

    function setPriceBounds(uint256 minPrice, uint256 maxPrice) public {
        require(msg.sender == minter, OnlyMinter());
        require(minPrice < maxPrice && minPrice > 0.98e18 && maxPrice < 1.02e18, PriceOutOfBounds());
        MIN_PRICE = minPrice;
        MAX_PRICE = maxPrice;
    }

    function setTimelocks(uint256 days1) public {
        require(msg.sender == minter, OnlyMinter());
        require(days1 > 1 hours && days1 <= 28 days);
        POSITION_TIMELOCK = days1;
    }

    function setSlippage(uint256 slippageBps) public {
        require(msg.sender == minter, OnlyMinter());
        require(slippageBps >= 1 && slippageBps <= 100);
        MAX_SLIPPAGE_BPS = slippageBps;
    }

    function setRange(int24 _range) public {
        require(msg.sender == minter, OnlyMinter());
        require(_range > 0 && _range <= 5, OutOfRange());
        RANGE = (_range * TICK_SPACING);
    }

    function setOffset(int24 _offset) public {
        require(msg.sender == minter, OnlyMinter());
        require(_offset >= 0 && _offset <= 2, OutOfRange());
        offset = _offset;
    }

    function setCustomRange(int24 _lowTickAdmin, int24 _highTickAdmin) public {
        require(msg.sender == minter, OnlyMinter());
        if(_highTickAdmin == 0 && _lowTickAdmin == 0) {
            lowTickAdmin = 0;
            highTickAdmin = 0;
            return;
        }
        require(_highTickAdmin > _lowTickAdmin);
        checkPriceBounds(TickMath.getSqrtPriceAtTick(_lowTickAdmin));
        checkPriceBounds(TickMath.getSqrtPriceAtTick(_highTickAdmin));
        lowTickAdmin = _lowTickAdmin;
        highTickAdmin = _highTickAdmin;
    }

    function tradeSamePool(uint8 direction) public {
        require(msg.sender == minter, OnlyMinter());
        require(direction <3);
        tradeThis = direction; //This is used when there are issues with external pools or calls. Then users should migrate to a new pool.
    }

    function lockMinter() public {
        require(msg.sender == minter, OnlyMinter());
        lockThis = true;
    }

    function minterOnly(bool _mintThis) public {
        require(msg.sender == minter, OnlyMinter());
        mintThis = _mintThis;
    }

    // ============ HELPER FUNCTIONS ============
    
    function _amount0(int256 delta) internal pure returns (int128) {
        return int128(int256(delta) >> 128);
    }

    function _amount1(int256 delta) internal pure returns (int128) {
        return int128(int256(delta));
    }

    function _getRequiredRatio(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper
    ) internal pure returns (uint256 ratio0) {
        if (sqrtPriceX96 <= sqrtPriceLower) return 10000;
        if (sqrtPriceX96 >= sqrtPriceUpper) return 0;
        uint256 distanceToUpper = uint256(sqrtPriceUpper - sqrtPriceX96);
        uint256 distanceToLower = uint256(sqrtPriceX96 - sqrtPriceLower);
        ratio0 = (distanceToUpper * 10000) / (distanceToUpper + distanceToLower);
    }

    function _getAmount0ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liq
    ) internal pure returns (uint256) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        return uint256(liq) * (sqrtPriceBX96 - sqrtPriceAX96) / (uint256(sqrtPriceAX96) * sqrtPriceBX96 / (1 << 96));
    }

    function _getAmount1ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liq
    ) internal pure returns (uint256) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        return uint256(liq) * (sqrtPriceBX96 - sqrtPriceAX96) / (1 << 96);
    }

    function checkPriceBounds(uint160 sqrtPriceX96) internal view {
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 price;
        if (_daiIsToken0()) {
            // DAI per USDC = 1e6 / price_raw
            price = (uint256(1e6) << 192) / priceX192;
        } else {
            // DAI per USDC = price_raw * 1e6
            price = (priceX192 * 1e6) >> 192;
        }
        if (price < MIN_PRICE || price > MAX_PRICE) {
            revert PriceOutOfBounds();
        }
    }

    // ============ USER FUNCTIONS ============

    function deposit(uint256 amount, uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0) {
            require(DAI.balanceOf(address(this)) > 0 || USDC.balanceOf(address(this)) > 0); //Compound existing DAI
        } else {
            DAI.transferFrom(msg.sender, address(this), amount);
        }        
        shares[msg.sender] += amount;
        IFeeVault(feeVault).addShares(msg.sender, amount);
        totalShares += amount;
        poolManager.unlock(abi.encode(ACTION_DEPOSIT, uint256(0), address(0)));
        emit Deposited(msg.sender, amount, amount);
    }

    function withdraw(uint256 shareAmount, uint256 deadline, bool addDust) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[msg.sender] < shareAmount) revert InsufficientShares();
        shares[msg.sender] -= shareAmount;
        try IFeeVault(feeVault).removeShares(msg.sender, shareAmount) {
        } catch {
            IFeeVault(feeVault).setMigrate();
            salvageFees = true; //Should probably never happen however it must never impede withdrawals
        }
        totalShares -= shareAmount;
        if(addDust) {
            poolManager.unlock(abi.encode(ACTION_WITHDRAW_DUST, shareAmount, msg.sender));
        } else {
            poolManager.unlock(abi.encode(ACTION_WITHDRAW, shareAmount, msg.sender));
        }
    }

    function collectFees(uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (liquidity == 0) revert NoPosition();
        poolManager.unlock(abi.encode(ACTION_COLLECT, uint256(0), address(0)));
    }

    function reposition(uint256 deadline) external nonReentrant {
        if(mintThis) {
            require(msg.sender == minter, OnlyMinter());
        }
        if (msg.sender != minter) {
            int24 ct = _getCurrentTick();
            if (ct >= tickLower && ct < tickUpper) revert PositionInRange();
        }
        if (block.timestamp > deadline) revert Expired();
        require(block.timestamp > lastReposition + POSITION_TIMELOCK, Expired());
        lastReposition = block.timestamp;
        if (liquidity == 0) revert NoPosition();
        poolManager.unlock(abi.encode(ACTION_REPOSITION, uint256(0), address(0)));
    }

    function cleanDust(uint256 deadline, uint256 amount) public nonReentrant {
        if(msg.sender != minter) {
            checkPriceBounds(_getCurrentSqrtPrice());
        }
        if (block.timestamp > deadline) revert Expired();
        poolManager.unlock(abi.encode(ACTION_CLEAN_DUST, amount, address(0)));
    }

    // ============ CALLBACK ============

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, uint256 amount, address recipient) = abi.decode(data, (uint8, uint256, address));
        if (action == ACTION_DEPOSIT) {
            _deposit();
        } else if (action == ACTION_WITHDRAW) {
            _withdraw(amount, recipient, false);
        } else if (action == ACTION_COLLECT) {
            _collect();
        } else if (action == ACTION_REPOSITION) {
            _reposition();
        } else if (action == ACTION_CLEAN_DUST) {
            _cleanDust(amount);
        } else if (action == ACTION_WITHDRAW_DUST) {
            _withdraw(amount, recipient, true);
        } else {
            revert UnknownAction();
        }
        return "";
    }

    // ============ INTERNAL HANDLERS ============

    function _deposit() internal {
        int24 currentTick = _getCurrentTick();
        int24 tl;
        int24 tu;
        if (liquidity == 0) { // New position
            tl = _alignTick(currentTick - RANGE);
            tu = _alignTick(currentTick + RANGE);
            if(offset < 0) {
                tl += (offset * TICK_SPACING);
            }
            if(offset > 0) {
                tu += (offset * TICK_SPACING);
            }
        } else {
            tl = tickLower;
            tu = tickUpper;
        }
        uint160 sqrtPriceX96 = _getCurrentSqrtPrice();
        if(tradeThis == 0) {
            checkPriceBounds(sqrtPriceX96);
        }
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tl);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tu);
        uint256 ratio0 = _getRequiredRatio(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper);
        bool daiIs0 = _daiIsToken0(); //This will also absorb prior dust and profits
        _collect();
        uint256 daiBal = DAI.balanceOf(address(this));
        uint256 swapAmount;
        if (daiIs0) {
            swapAmount = (daiBal * (10000 - ratio0)) / 10000;
            if (swapAmount > 0) _daitrade(swapAmount);
        } else {
            swapAmount = (daiBal * ratio0) / 10000;
            if (swapAmount > 0) _daitrade(swapAmount);
        }
        // Refresh after swap
        daiBal = DAI.balanceOf(address(this));
        uint256 usdcBal = USDC.balanceOf(address(this));
        sqrtPriceX96 = _getCurrentSqrtPrice();
        uint256 amount0 = daiIs0 ?  daiBal : usdcBal;
        uint256 amount1 = daiIs0 ?  usdcBal : daiBal;
        uint128 newLiquidity;
        if (sqrtPriceX96 <= sqrtPriceLower) {
            newLiquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount0); //Price below range
        } else if (sqrtPriceX96 >= sqrtPriceUpper) {
            newLiquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, amount1); //Price above range
        } else {
            // Calculate which token is the constraint
            uint128 liq0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpper, amount0);
            uint256 required1 = _getAmount1ForLiquidity(sqrtPriceLower, sqrtPriceX96, liq0);
            if (required1 <= amount1) {
                newLiquidity = liq0;
            } else {
                newLiquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceX96, amount1);
            }
        }
        if (newLiquidity > 0) {
            _modifyLiquidity(tl, tu, int128(newLiquidity));
            if (liquidity == 0) {
                tickLower = tl;
                tickUpper = tu;
            }
            liquidity += newLiquidity;
        }
    }

    function _withdraw(uint256 shareAmount, address recipient, bool addDust) internal {
        if (liquidity == 0) {
            uint256 daiBal = DAI.balanceOf(address(this));
            uint256 usdcBal = USDC.balanceOf(address(this));
            if (daiBal > 0) DAI.transfer(recipient, daiBal);
            if (usdcBal > 0) USDC.transfer(recipient, usdcBal);
            emit Withdrawn(recipient, shareAmount, daiBal, usdcBal);
            return;
        }
        if((DAI.balanceOf(address(this)) > 0 || USDC.balanceOf(address(this)) > 0) && addDust) {
            _deposit();
        } else {
            if(tradeThis == 0) {
                _collect();
            }
        }
        uint256 currentTotalShares = totalShares + shareAmount;
        uint128 toRemove = uint128((uint256(liquidity) * shareAmount) / currentTotalShares);
        require(toRemove > 0, ZeroAmount());
        // Get balances before to exclude dust
        uint256 daiBefore = DAI.balanceOf(address(this));
        uint256 usdcBefore = USDC.balanceOf(address(this));
        _modifyLiquidity(tickLower, tickUpper, -int128(toRemove));
        liquidity -= toRemove;
        uint256 daiOut = DAI.balanceOf(address(this)) - daiBefore;
        uint256 usdcOut = USDC.balanceOf(address(this)) - usdcBefore;
        if (daiOut > 0) DAI.transfer(recipient, daiOut);
        if (usdcOut > 0) USDC.transfer(recipient, usdcOut);
        emit Withdrawn(recipient, shareAmount, daiOut, usdcOut);
    }

    function _collect() internal {
        if (liquidity == 0) return;
        (int256 delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 0,
                salt: salt
            }),
            ""
        );
        int128 a0 = _amount0(delta);
        int128 a1 = _amount1(delta);
        uint256 posval = getPositionValue() + DAI.balanceOf(address(this)) + (USDC.balanceOf(address(this)) * 1e12);
        bool daiIs0 = _daiIsToken0();
        if (posval < totalShares) {
            uint256 shortfall = totalShares - posval;
            if (daiIs0) {
                if (a0 > 0) {
                    uint256 u0 = uint256(uint128(a0));
                    if (u0 > shortfall) {
                        poolManager.take(poolKey.currency0, address(this), uint128(shortfall));
                        a0 = int128(int256(u0 - shortfall));
                    } else {
                        poolManager.take(poolKey.currency0, address(this), uint128(a0));
                        a0 = 0;
                    }
                }
            } else {
                if (a1 > 0) {
                    uint256 u1 = uint256(uint128(a1));
                    if (u1 > shortfall) {
                        poolManager.take(poolKey.currency1, address(this), uint128(shortfall));
                        a1 = int128(int256(u1 - shortfall));
                    } else {
                        poolManager.take(poolKey.currency1, address(this), uint128(a1));
                        a1 = 0;
                    }
                }
            }
        }
        int128 c0 = (a0 * commission) / 100;
        int128 c1 = (a1 * commission) / 100;
        if (a0 > 0 || a1 > 0) {
            if (a0 > 0) weeklyRewards[block.timestamp / 7 days][poolKey.currency0] += uint256(uint128(a0));
            if (a1 > 0) weeklyRewards[block.timestamp / 7 days][poolKey.currency1] += uint256(uint128(a1));
        }
        if (c0 > 0) poolManager.take(poolKey.currency0, treasury, uint128(c0));
        if (c1 > 0) poolManager.take(poolKey.currency1, treasury, uint128(c1));
        if (a0 > 0) poolManager.take(poolKey.currency0, feeVault, uint128(a0-c0));
        if (a1 > 0) poolManager.take(poolKey.currency1, feeVault, uint128(a1-c1));
        emit FeesCollected(a0 > 0 ? uint128(a0) : 0, a1 > 0 ? uint128(a1) : 0);
    }

    struct RepositionState {
        int24 currentTick;
        int24 newTickLower;
        int24 newTickUpper;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        bool daiIs0;
    }

    function _reposition() internal {
        RepositionState memory s;
        s.currentTick = _getCurrentTick();
        _collect();
        _modifyLiquidity(tickLower, tickUpper, -int128(liquidity));
        bool crossedUp = s.currentTick >= tickUpper;
        if (crossedUp) {
            // Range extends downward (toward peg), currentTick near top
            s.newTickUpper = _alignTick(s.currentTick + TICK_SPACING);
            s.newTickLower = _alignTick(s.currentTick - (RANGE * 2) + TICK_SPACING - (offset * TICK_SPACING));
        } else {
            // Range extends upward (toward peg), currentTick near bottom
            s.newTickLower = _alignTick(s.currentTick);
            s.newTickUpper = _alignTick(s.currentTick + (RANGE * 2) + (offset * TICK_SPACING));
        }
        if(lowTickAdmin != 0 || highTickAdmin != 0) {
            s.newTickLower = lowTickAdmin;
            s.newTickUpper = highTickAdmin;
            require(s.currentTick >= s.newTickLower && s.currentTick < s.newTickUpper, OutOfRange());
        }
        s.sqrtPriceX96 = _getCurrentSqrtPrice();
        checkPriceBounds(s.sqrtPriceX96);
        s.sqrtPriceLower = TickMath.getSqrtPriceAtTick(s.newTickLower);
        s.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(s.newTickUpper);
        s.daiIs0 = _daiIsToken0();
        uint256 daiBal = DAI.balanceOf(address(this));
        uint256 usdcBal = USDC.balanceOf(address(this));
        // Normalize to 18 decimals
        uint256 daiNormalized = daiBal;
        uint256 usdcNormalized = usdcBal * 1e12;
        uint256 totalNormalized = daiNormalized + usdcNormalized;
        uint256 ratio0 = _getRequiredRatio(s.sqrtPriceX96, s.sqrtPriceLower, s.sqrtPriceUpper);
        // Calculate target DAI in normalized terms
        uint256 targetDaiNormalized = s.daiIs0 
            ? (totalNormalized * ratio0) / 10000 
            : (totalNormalized * (10000 - ratio0)) / 10000;
        if (daiNormalized > targetDaiNormalized) {
            // Too much DAI, swap DAI for USDC
            uint256 swapAmount = daiNormalized - targetDaiNormalized; // Already 18 decimals
            if (swapAmount > 0) _daitrade(swapAmount);
        } else if (daiNormalized < targetDaiNormalized) {
            // Too little DAI, swap USDC for DAI
            uint256 swapAmountNormalized = targetDaiNormalized - daiNormalized;
            uint256 swapAmount = swapAmountNormalized / 1e12; // Convert to 6 decimals for USDC
            if (swapAmount > 0) _usdctrade(swapAmount);
        }
        // Refresh after swap
        daiBal = DAI.balanceOf(address(this));
        usdcBal = USDC.balanceOf(address(this));
        s.sqrtPriceX96 = _getCurrentSqrtPrice();
        uint256 amount0 = s.daiIs0 ? daiBal : usdcBal;
        uint256 amount1 = s.daiIs0 ? usdcBal :  daiBal;
        uint128 liq0 = LiquidityAmounts.getLiquidityForAmount0(s.sqrtPriceX96, s.sqrtPriceUpper, amount0);
        uint256 required1 = _getAmount1ForLiquidity(s.sqrtPriceLower, s.sqrtPriceX96, liq0);
        uint128 newLiquidity;
        if (required1 <= amount1) {
            newLiquidity = liq0;
        } else {
            newLiquidity = LiquidityAmounts.getLiquidityForAmount1(s.sqrtPriceLower, s.sqrtPriceX96, amount1);
        }
        if (newLiquidity > 0) {
            _modifyLiquidity(s.newTickLower, s.newTickUpper, int128(newLiquidity));
        }
        tickLower = s.newTickLower;
        tickUpper = s.newTickUpper;
        liquidity = newLiquidity;
        emit Repositioned(s.newTickLower, s.newTickUpper, newLiquidity);
    }

    function _cleanDust(uint256 amt) internal {
        uint256 usdcBalance = 0;
        uint256 daiBalance = 0;
        uint256 swapOut = 0;
        if(tradeThis == 2) {
            daiBalance = DAI.balanceOf(address(this));
            if(amt > 0 && amt < daiBalance) {
                daiBalance = amt;
            }
            swapOut = _swap(daiBalance, _daiIsToken0());
        } else {
            usdcBalance = USDC.balanceOf(address(this));
            if(amt > 0 && amt < usdcBalance) {
                usdcBalance = amt;
            }
            if (usdcBalance > 100000) {
                if(tradeThis == 0) {
                    swapOut = _usdctrade(usdcBalance);
                }
                if(tradeThis == 1) {
                    swapOut = _swap(usdcBalance, !_daiIsToken0());
                }
            }
        }
        daiBalance = DAI.balanceOf(address(this));
        emit DustCleaned(daiBalance, swapOut);
    }

    // ============ POOL OPERATIONS ============

    function _modifyLiquidity(int24 tl, int24 tu, int128 delta) internal {
        (int256 callerDelta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tl,
                tickUpper: tu,
                liquidityDelta:  delta,
                salt: salt
            }),
            ""
        );
        _settle(callerDelta);
    }

    function _swap(uint256 amountIn, bool zeroForOne) internal returns (uint256 amountOut){
        bool daiIs0 = _daiIsToken0();
        bool inIsDai = (zeroForOne == daiIs0);
        if (inIsDai && amountIn / 1e15 == 0) return 0;
        int256 delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne:  zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settle(delta);
        amountOut = uint256(uint128(zeroForOne ? _amount1(delta) : _amount0(delta)));
        uint256 inValue = inIsDai ? amountIn :  amountIn * 1e12;
        uint256 outValue = inIsDai ? amountOut * 1e12 : amountOut;
        if (outValue < (inValue * (10000 - MAX_SLIPPAGE_BPS)) / 10000) {
            revert SlippageExceeded();
        }
    }

    function _swapHop(PoolKey memory key, address tokenIn, uint256 amountIn, uint8 inDecimals, uint8 outDecimals) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        bool zeroForOne = (key.currency0 == tokenIn);
        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settleKey(key, delta);
        amountOut = uint256(uint128(zeroForOne ? _amount1(delta) : _amount0(delta)));
        // normalize both sides to 18-dec value and enforce per-hop slippage
        uint256 inValue  = inDecimals  == 18 ? amountIn  : amountIn  * (10 ** (18 - inDecimals));
        uint256 outValue = outDecimals == 18 ? amountOut : amountOut * (10 ** (18 - outDecimals));
        if (outValue < (inValue * (10000 - MAX_SLIPPAGE_BPS)) / 10000) revert SlippageExceeded();
    }

    function _daitrade(uint256 amountIn) internal returns (uint256 usdcOut) {
        uint256 usdtOut = _swapHop(daiKey, address(DAI),  amountIn, 18, 6);
        usdcOut         = _swapHop(usdcKey, address(USDT), usdtOut, 6,  6);
    }

    function _usdctrade(uint256 amountIn) internal returns (uint256 daiOut) {
        uint256 usdtOut = _swapHop(usdcKey, address(USDC), amountIn, 6, 6);
        daiOut          = _swapHop(daiKey, address(USDT), usdtOut, 6, 18);
    }

    function _settle(int256 delta) internal {
        _settleKey(poolKey, delta);
    }

    function _settleKey(PoolKey memory key, int256 delta) internal {
        int128 a0 = _amount0(delta);
        int128 a1 = _amount1(delta);
        if (a0 < 0) {
            poolManager.sync(key.currency0);
            IERC20(key.currency0).transfer(address(poolManager), uint128(-a0));
            poolManager.settle();
        } else if (a0 > 0) {
            poolManager.take(key.currency0, address(this), uint128(a0));
        }
        if (a1 < 0) {
            poolManager.sync(key.currency1);
            IERC20(key.currency1).transfer(address(poolManager), uint128(-a1));
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint128(a1));
        }
    }

    // ============ VIEW FUNCTIONS ============

    function _daiIsToken0() public view returns (bool) {
        return poolKey.currency0 == address(DAI);
    }

    function _alignTick(int24 tick) public view returns (int24) {
        int24 spacing = poolKey.tickSpacing;
        if(spacing == 1) {
            return tick;
        }
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _getCurrentSqrtPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = stateView.getSlot0(keccak256(abi.encode(poolKey)));
    }

    function _getCurrentTick() public view returns (int24 tick) {
        (, tick,,) = stateView.getSlot0(keccak256(abi.encode(poolKey)));
    }
    
    function getUnclaimedFees() external view returns (uint256 fee0, uint256 fee1) {
        if (liquidity == 0) return (0, 0);
        bytes32 poolId = keccak256(abi.encode(poolKey));
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = stateView.getFeeGrowthInside(poolId, tickLower, tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = stateView.getPositionInfo(poolId, address(this), tickLower, tickUpper, salt);
        unchecked {
            fee0 = uint256(liquidity) * (feeGrowthInside0X128 - feeGrowthInside0LastX128) / (1 << 128);
            fee1 = uint256(liquidity) * (feeGrowthInside1X128 - feeGrowthInside1LastX128) / (1 << 128);
        }
    }

    function getPosition() external view returns (int24, int24, uint128) {
        return (tickLower, tickUpper, liquidity);
    }

    function getUserShares(address user) external view returns (uint256) {
        return shares[user];
    }

    function getBalances() external view returns (uint256 daiBalance, uint256 usdcBalance) {
        return (DAI.balanceOf(address(this)), USDC.balanceOf(address(this)));
    }

    function getPositionValue() public view returns (uint256) {
        if (liquidity == 0) return 0;
        uint160 sqrtPriceX96 = _getCurrentSqrtPrice();
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        // Clamp price to range
        uint160 sqrtPriceClamped = sqrtPriceX96;
        if (sqrtPriceX96 < sqrtPriceLower) sqrtPriceClamped = sqrtPriceLower;
        if (sqrtPriceX96 > sqrtPriceUpper) sqrtPriceClamped = sqrtPriceUpper;
        uint256 amount0 = _getAmount0ForLiquidity(sqrtPriceClamped, sqrtPriceUpper, liquidity);
        uint256 amount1 = _getAmount1ForLiquidity(sqrtPriceLower, sqrtPriceClamped, liquidity);
        bool daiIs0 = _daiIsToken0();
        if (daiIs0) {
            return amount0 + (amount1 * 1e12);
        } else {
            return amount1 + (amount0 * 1e12);
        }
    }

    function getTotalAssets() public view returns (uint256) {
        uint256 positionValue = getPositionValue();               // Liquidity in pool
        uint256 daiBal = DAI.balanceOf(address(this));            // Dust/pending DAI
        uint256 usdcBal = USDC.balanceOf(address(this)) * 1e12;   // Dust/pending USDC (normalized)
        return positionValue + daiBal + usdcBal;
    }

    function isInRange() external view returns (bool) {
        if (liquidity == 0) return false;
        int24 currentTick = _getCurrentTick();
        return currentTick >= tickLower && currentTick < tickUpper;
    }
}