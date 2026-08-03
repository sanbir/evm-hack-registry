// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test, console} from "forge-std/Test.sol";

import {BorrowingTest} from "../src/TestContracts/CopyBorrowing.sol";
import {CDSTest} from "../src/TestContracts/CopyCDS.sol";
import {TestUSDaStablecoin} from "../src/TestContracts/CopyUSDa.sol";
import {TestABONDToken} from "../src/TestContracts/Copy_Abond_Token.sol";
import {TestUSDT} from "../src/TestContracts/CopyUsdt.sol";
import {WEETH} from "../src/TestContracts/MockWeETH.sol";
import {RSETH} from "../src/TestContracts/MockRsETH.sol";
import {EndpointV2Mock} from "../src/TestContracts/EndpointV2Mock.sol";
import {MockV3Aggregator} from "../src/testmocks/MockV3Aggregator.sol";

import {Treasury} from "../src/Core_logic/Treasury.sol";
import {GlobalVariables} from "../src/Core_logic/GlobalVariables.sol";
import {Options} from "../src/Core_logic/Options.sol";
import {MultiSign} from "../src/Core_logic/multiSign.sol";
import {BorrowLiquidation} from "../src/Core_logic/borrowLiquidation.sol";
import {MasterPriceOracle} from "../src/oracles/MasterPriceOracle.sol";

import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {IGlobalVariables} from "../src/interface/IGlobalVariables.sol";

import {WETH9Double, IonicDouble, SynthetixWrapperDouble, SynthetixExchangeDouble, PerpsV2Double, RedstoneOracleDouble} from "../src/testmocks/ExternalDoubles.sol";

/// @dev Full local deployment of the real Autonomint protocol, mirroring the repo's
/// own DeployBorrowing script but replacing the forked external protocols (Ionic
/// lending, Synthetix perps, WETH) with minimal real doubles so it runs with NO
/// mainnet fork. Everything in Core_logic + lib is the real audited source.
abstract contract AutonomintBase is Test {
    struct Contracts {
        WEETH weeth;
        RSETH rseth;
        TestUSDaStablecoin usda;
        TestABONDToken abond;
        MultiSign multiSign;
        TestUSDT usdt;
        CDSTest cds;
        GlobalVariables global;
        BorrowingTest borrow;
        BorrowLiquidation borrowLiquidation;
        Treasury treasury;
        Options option;
    }

    Contracts internal A;
    Contracts internal B;

    // Repo owners (Anvil default accounts)
    address internal owner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal owner1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal owner2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address[] internal owners = [owner, owner1, owner2];
    uint8[] internal functionsList = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

    // Sentinel ETH "address" used by the protocol
    address internal constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint32 internal eidA = 1;
    uint32 internal eidB = 2;

    EndpointV2Mock internal endpointA;
    EndpointV2Mock internal endpointB;

    // Shared external-protocol doubles (per chain)
    WETH9Double internal wethA;
    IonicDouble internal ionicA;
    WETH9Double internal wethB;
    IonicDouble internal ionicB;

    RedstoneOracleDouble internal oracle;

    // Fixed link addresses for the two public libraries (must match foundry.toml
    // `libraries=`). The synthetic Playground injects the same runtime at these
    // addresses via anvil_state; here we etch them for the forge test.
    address internal constant CDSLIB_ADDR = 0x0000000000000000000000000000000000000cD5;
    address internal constant BORROWLIB_ADDR = 0x0000000000000000000000000000000000000B0b;

    function _deployAll() internal {
        vm.etch(CDSLIB_ADDR, vm.getDeployedCode("CDSLib.sol:CDSLib"));
        vm.etch(BORROWLIB_ADDR, vm.getDeployedCode("BorrowLib.sol:BorrowLib"));

        vm.startPrank(owner);

        endpointA = new EndpointV2Mock(eidA);
        endpointB = new EndpointV2Mock(eidB);

        // one controllable RedStone-style oracle shared by both master oracles
        oracle = new RedstoneOracleDouble();

        A = _deploySet(endpointA);
        B = _deploySet(endpointB);

        // Cross endpoint wiring (mirror DeployBorrowing)
        endpointA.setDestLzEndpoint(address(B.usda), address(endpointB));
        endpointA.setDestLzEndpoint(address(B.usdt), address(endpointB));
        endpointA.setDestLzEndpoint(address(B.global), address(endpointB));
        endpointA.setDestLzEndpoint(address(B.weeth), address(endpointB));
        endpointA.setDestLzEndpoint(address(B.rseth), address(endpointB));

        endpointB.setDestLzEndpoint(address(A.usda), address(endpointA));
        endpointB.setDestLzEndpoint(address(A.usdt), address(endpointA));
        endpointB.setDestLzEndpoint(address(A.global), address(endpointA));
        endpointB.setDestLzEndpoint(address(A.weeth), address(endpointA));
        endpointB.setDestLzEndpoint(address(A.rseth), address(endpointA));

        vm.stopPrank();

        _wire();
    }

    function _deploySet(EndpointV2Mock endpoint) internal returns (Contracts memory c) {
        c.usda = new TestUSDaStablecoin();
        c.abond = new TestABONDToken();
        c.multiSign = new MultiSign();
        c.usdt = new TestUSDT();
        c.cds = new CDSTest();
        c.borrow = new BorrowingTest();
        c.treasury = new Treasury();
        c.option = new Options();
        c.borrowLiquidation = new BorrowLiquidation();
        c.global = new GlobalVariables();
        c.weeth = new WEETH();
        c.rseth = new RSETH();

        c.weeth.initialize(address(endpoint), owner);
        c.rseth.initialize(address(endpoint), owner);

        address[] memory priceFeeds = new address[](4);
        priceFeeds[0] = address(oracle);
        priceFeeds[1] = address(oracle);
        priceFeeds[2] = address(oracle);
        priceFeeds[3] = address(oracle);

        address[] memory collaterals = new address[](4);
        collaterals[0] = ETH_SENTINEL;
        collaterals[1] = address(c.weeth);
        collaterals[2] = address(c.rseth);
        collaterals[3] = address(c.rseth);

        MasterPriceOracle mpo = new MasterPriceOracle(collaterals, priceFeeds);

        address[] memory tokens = new address[](3);
        tokens[0] = address(c.usda);
        tokens[1] = address(c.abond);
        tokens[2] = address(c.usdt);

        c.usda.initialize(address(endpoint), owner);
        c.abond.initialize();
        c.multiSign.initialize(owners, 2);
        c.usdt.initialize(address(endpoint), owner);
        c.cds.initialize(address(c.usda), address(mpo), address(c.usdt), address(c.multiSign));
        c.global.initialize(address(c.usda), address(c.cds), address(endpoint), owner);
        c.borrow.initialize(
            address(c.usda),
            address(c.cds),
            address(c.abond),
            address(c.multiSign),
            address(mpo),
            collaterals,
            tokens,
            uint64(block.chainid),
            address(c.global)
        );

        // external-protocol doubles for this chain
        WETH9Double weth = new WETH9Double();
        IonicDouble ionic = new IonicDouble(address(weth));
        SynthetixWrapperDouble wrapper = new SynthetixWrapperDouble();
        SynthetixExchangeDouble synthetix = new SynthetixExchangeDouble();
        PerpsV2Double perps = new PerpsV2Double();

        c.borrowLiquidation.initialize(
            address(c.borrow),
            address(c.cds),
            address(c.usda),
            address(c.global),
            address(weth),
            address(wrapper),
            address(perps),
            address(synthetix)
        );
        c.treasury.initialize(
            address(c.borrow),
            address(c.usda),
            address(c.abond),
            address(c.cds),
            address(c.borrowLiquidation),
            address(c.usdt),
            address(c.global)
        );
        c.option.initialize(address(c.treasury), address(c.cds), address(c.borrow), address(c.global));

        // stash the doubles for the ETH chain (set A / set B) via storage below
        if (address(wethA) == address(0)) {
            wethA = weth;
            ionicA = ionic;
        } else {
            wethB = weth;
            ionicB = ionic;
        }
    }

    function _wire() internal {
        // weeth/rseth peers
        vm.startPrank(owner);
        A.weeth.setPeer(eidB, bytes32(uint256(uint160(address(B.weeth)))));
        A.rseth.setPeer(eidB, bytes32(uint256(uint160(address(B.rseth)))));
        B.weeth.setPeer(eidA, bytes32(uint256(uint160(address(A.weeth)))));
        B.rseth.setPeer(eidA, bytes32(uint256(uint160(address(A.rseth)))));

        A.usda.setPeer(eidB, bytes32(uint256(uint160(address(B.usda)))));
        A.usdt.setPeer(eidB, bytes32(uint256(uint160(address(B.usdt)))));
        A.global.setPeer(eidB, bytes32(uint256(uint160(address(B.global)))));
        B.usda.setPeer(eidA, bytes32(uint256(uint160(address(A.usda)))));
        B.usdt.setPeer(eidA, bytes32(uint256(uint160(address(A.usdt)))));
        B.global.setPeer(eidA, bytes32(uint256(uint160(address(A.global)))));

        A.usda.setDstEid(eidB);
        A.usdt.setDstEid(eidB);
        A.global.setDstEid(eidB);
        B.usda.setDstEid(eidA);
        B.usdt.setDstEid(eidA);
        B.global.setDstEid(eidA);

        _wireSet(A, wethA, ionicA);
        _wireSet(B, wethB, ionicB);

        // multisig approvals (owner + owner1)
        A.multiSign.approveSetterFunction(functionsList);
        B.multiSign.approveSetterFunction(functionsList);
        vm.stopPrank();
        vm.startPrank(owner1);
        A.multiSign.approveSetterFunction(functionsList);
        B.multiSign.approveSetterFunction(functionsList);
        vm.stopPrank();

        vm.startPrank(owner);
        _configSet(A, wethA, ionicA);
        _configSet(B, wethB, ionicB);
        A.borrow.calculateCumulativeRate();
        B.borrow.calculateCumulativeRate();
        vm.stopPrank();
    }

    function _wireSet(Contracts memory c, WETH9Double weth, IonicDouble ionic) internal {
        c.usda.setBorrowingContract(address(c.borrow));
        c.usda.setCdsContract(address(c.cds));
        c.usda.setTreasuryContract(address(c.treasury));
        c.abond.setBorrowingContract(address(c.borrow));

        c.global.setTreasury(address(c.treasury));
        c.global.setBorrowLiq(address(c.borrowLiquidation));
        c.global.setBorrowing(address(c.borrow));

        c.borrowLiquidation.setTreasury(address(c.treasury));
        c.borrowLiquidation.setAdmin(owner);
    }

    function _configSet(Contracts memory c, WETH9Double weth, IonicDouble ionic) internal {
        // dst global addresses
        if (address(c.global) == address(A.global)) {
            c.global.setDstGlobalVariablesAddress(address(B.global));
        } else {
            c.global.setDstGlobalVariablesAddress(address(A.global));
        }

        c.borrow.setAdmin(owner);
        c.borrow.setTreasury(address(c.treasury));
        c.borrow.setOptions(address(c.option));
        c.borrow.setBorrowLiquidation(address(c.borrowLiquidation));
        c.borrow.setLTV(80);
        c.borrow.setBondRatio(4);
        // ratePerSec = 1e27 => 0% borrow interest. Interest accrual is orthogonal to
        // all three accounting bugs; setting it to zero removes the unrelated
        // time-advancement requirement (normalizedAmount == borrowedAmount exactly),
        // so the exploit runs in a single block (needed for the cheatcode-free replay).
        c.borrow.setAPR(50, 1000000000000000000000000000);

        c.cds.setAdmin(owner);
        c.cds.setTreasury(address(c.treasury));
        c.cds.setBorrowingContract(address(c.borrow));
        c.cds.setBorrowLiquidation(address(c.borrowLiquidation));
        c.cds.setUSDaLimit(80);
        c.cds.setUsdtLimit(20000000000);
        c.cds.setGlobalVariables(address(c.global));

        // external protocol addresses -> our local doubles (ionic, weth, odos)
        c.treasury.setExternalProtocolAddresses(address(ionic), address(weth), address(weth));
    }
}
