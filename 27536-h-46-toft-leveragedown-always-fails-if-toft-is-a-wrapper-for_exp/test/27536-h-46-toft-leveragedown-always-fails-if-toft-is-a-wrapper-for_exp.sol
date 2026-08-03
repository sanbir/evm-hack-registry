// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {TapiocaOFT} from "../src/tOFT/TapiocaOFT.sol";
import {BaseTOFTLeverageModule} from "../src/tOFT/modules/BaseTOFTLeverageModule.sol";
import {BaseTOFTStrategyModule} from "../src/tOFT/modules/BaseTOFTStrategyModule.sol";
import {BaseTOFTMarketModule} from "../src/tOFT/modules/BaseTOFTMarketModule.sol";
import {BaseTOFTOptionsModule} from "../src/tOFT/modules/BaseTOFTOptionsModule.sol";

import {IYieldBoxBase} from "tapioca-periph/contracts/interfaces/IYieldBoxBase.sol";
import {IUSDOBase} from "tapioca-periph/contracts/interfaces/IUSDO.sol";

import {TestERC20, MockLZEndpoint, MockSwapper, MockMagnetar, MockUSDO} from "../src/mocks/Mocks.sol";

/// @title H-46 — TOFT.leverageDown always fails when the TOFT wraps the native gas token
/// @notice Tapioca-DAO/tapiocaz-audit @ bcf61f79464cfdc0484aa272f9f6e28d5de36a8f
///         (C4 2023-07-tapioca). Vulnerable line:
///         contracts/tOFT/modules/BaseTOFTLeverageModule.sol:215
///           `IERC20(erc20).approve(externalData.swapper, amount);`
///         For a native-wrapping TOFT `erc20 == address(0)`, so the high-level ERC20 call
///         to a codeless address reverts (extcodesize guard) *before* the swapper is ever
///         reached. The destination leverage-down message can NEVER succeed => the
///         position can never be de-leveraged; the source-side burned TOFT + airdrop are
///         permanently lost.
contract H46_TOFT_LeverageDown_Native is Test {
    uint16 constant HOST_CHAIN = 1;
    uint16 constant SRC_CHAIN = 2;
    uint64 constant NONCE = 1;
    uint256 constant AMOUNT = 1e18;

    MockLZEndpoint endpoint;
    MockSwapper swapper;
    MockMagnetar magnetar;
    MockUSDO usdo;

    bytes srcPath; // trusted remote path (remoteAddr .. localAddr)

    function setUp() public {
        endpoint = new MockLZEndpoint();
        swapper = new MockSwapper();
        magnetar = new MockMagnetar();
        usdo = new MockUSDO();
    }

    // Deploy a real TapiocaOFT (main + real leverage module) for a given underlying.
    function _deployTOFT(address underlying) internal returns (TapiocaOFT toft) {
        IYieldBoxBase yb = IYieldBoxBase(address(0));
        BaseTOFTLeverageModule lev = new BaseTOFTLeverageModule(
            address(endpoint), underlying, yb, "T", "T", 18, HOST_CHAIN
        );
        BaseTOFTStrategyModule strat = new BaseTOFTStrategyModule(
            address(endpoint), underlying, yb, "T", "T", 18, HOST_CHAIN
        );
        BaseTOFTMarketModule mkt = new BaseTOFTMarketModule(
            address(endpoint), underlying, yb, "T", "T", 18, HOST_CHAIN
        );
        BaseTOFTOptionsModule opt = new BaseTOFTOptionsModule(
            address(endpoint), underlying, yb, "T", "T", 18, HOST_CHAIN
        );
        toft = new TapiocaOFT(
            address(endpoint),
            underlying,
            yb,
            "T",
            "T",
            18,
            HOST_CHAIN,
            payable(address(lev)),
            payable(address(strat)),
            payable(address(mkt)),
            payable(address(opt))
        );

        // trust the source path so lzReceive accepts the inbound packet
        srcPath = abi.encodePacked(address(0xBEEF), address(toft));
        toft.setTrustedRemote(SRC_CHAIN, srcPath);
    }

    // Build the real PT_LEVERAGE_MARKET_DOWN payload the same way sendForLeverage encodes it.
    function _leveragePayload(address leverageFor) internal view returns (bytes memory) {
        IUSDOBase.ILeverageSwapData memory swapData = IUSDOBase.ILeverageSwapData({
            tokenOut: address(usdo),
            amountOutMin: 0,
            data: ""
        });
        IUSDOBase.ILeverageExternalContractsData memory externalData = IUSDOBase
            .ILeverageExternalContractsData({
            swapper: address(swapper),
            magnetar: address(magnetar),
            tOft: address(0),
            srcMarket: address(0xDEAD)
        });
        IUSDOBase.ILeverageLZData memory lzData = IUSDOBase.ILeverageLZData({
            srcExtraGasLimit: 200_000,
            lzSrcChainId: SRC_CHAIN,
            lzDstChainId: HOST_CHAIN,
            zroPaymentAddress: address(0),
            dstAirdropAdapterParam: "",
            srcAirdropAdapterParam: "",
            refundAddress: address(this)
        });
        // uint16 packetType, bytes32 sender, uint256 amount, swapData, externalData, lzData, leverageFor
        return abi.encode(
            uint16(776), // PT_LEVERAGE_MARKET_DOWN
            bytes32(uint256(uint160(address(0xBEEF)))),
            AMOUNT,
            swapData,
            externalData,
            lzData,
            leverageFor
        );
    }

    function _deliver(TapiocaOFT toft, bytes memory payload) internal {
        vm.prank(address(endpoint));
        toft.lzReceive(SRC_CHAIN, srcPath, NONCE, payload);
    }

    // ---------------------------------------------------------------------
    // VULNERABILITY: native-wrapping TOFT leverageDown permanently fails.
    // CONTROL:       identical ERC20-wrapping TOFT succeeds end-to-end.
    // ---------------------------------------------------------------------
    function test_leverageDown_native_always_fails_control_erc20_succeeds() public {
        // ================= VULNERABLE: native (erc20 == address(0)) =================
        TapiocaOFT nativeToft = _deployTOFT(address(0));
        assertEq(nativeToft.erc20(), address(0), "native TOFT must have erc20==address(0)");
        // TOFT holds the wrapped native it minted TOFT against
        vm.deal(address(nativeToft), AMOUNT);

        bytes memory payload = _leveragePayload(address(this));
        _deliver(nativeToft, payload);

        // The inbound leverage-down message FAILED and was parked in failedMessages.
        bytes32 stored = nativeToft.failedMessages(SRC_CHAIN, srcPath, NONCE);
        assertEq(stored, keccak256(payload), "native leverageDown must be a stored FAILED message");

        // It died at line 215 (approve on address(0)) BEFORE ever reaching the swapper.
        assertFalse(swapper.swapReached(), "native path must not reach the swapper");

        // Retrying the exact same payload keeps failing forever (message re-parked, never clears).
        vm.prank(address(endpoint));
        nativeToft.lzReceive(SRC_CHAIN, srcPath, NONCE, payload);
        assertEq(
            nativeToft.failedMessages(SRC_CHAIN, srcPath, NONCE),
            keccak256(payload),
            "retry of native leverageDown still fails => permanent DoS"
        );

        // ================= CONTROL: real ERC20 underlying =================
        TestERC20 underlying = new TestERC20();
        TapiocaOFT erc20Toft = _deployTOFT(address(underlying));
        assertTrue(erc20Toft.erc20() != address(0), "control TOFT must wrap a real ERC20");
        // TOFT holds the wrapped underlying it minted TOFT against
        underlying.mint(address(erc20Toft), AMOUNT);

        bytes memory payload2 = _leveragePayload(address(this));
        _deliver(erc20Toft, payload2);

        // No failed message: leverageDown completed end-to-end for the ERC20 TOFT.
        assertEq(
            erc20Toft.failedMessages(SRC_CHAIN, srcPath, NONCE),
            bytes32(0),
            "ERC20 leverageDown must succeed (no failed message)"
        );
        // And it got PAST the approve, reaching the swapper + repay legs.
        assertTrue(swapper.swapReached(), "ERC20 path reaches swap (past the approve)");
        assertTrue(usdo.repayReached(), "ERC20 path reaches repay");

        emit log_string(
            "H-46 CONFIRMED: native-wrapping TOFT can NEVER leverageDown (DoS at approve on address(0)); ERC20 TOFT succeeds."
        );
    }
}
