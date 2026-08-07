// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

// ---- REAL audited (pre-fix) DIA Spectra interoperability source ----
// diadata-org/Spectra-interoperability @ ed9f1e5ff3aa6cfba02d12f0bed1e435aeec24c1
import {OracleRequestRecipient} from "../src/OracleRequestRecipient.sol";
import {OracleTrigger} from "../src/OracleTrigger.sol";
import {ProtocolFeeHook} from "../src/ProtocolFeeHook.sol";
import {IOracleTrigger} from "../src/interfaces/IOracleTrigger.sol";
import {IMessageRecipient} from "../src/interfaces/IMessageRecipient.sol";
import {IPostDispatchHook} from "../src/interfaces/hooks/IPostDispatchHook.sol";

/*//////////////////////////////////////////////////////////////////////////
                        OPAQUE EXTERNAL BOUNDARIES ONLY
    The two doubles below stand in for genuinely-external infrastructure that
    is out of the finding's scope: the Hyperlane Mailbox (the cross-chain
    messenger) and the DIA oracle feed. The vulnerable contracts on the
    exploit path (OracleRequestRecipient, OracleTrigger) and the real fee hook
    (ProtocolFeeHook) are the ACTUAL audited source, unmodified.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal faithful Hyperlane Mailbox double. It reproduces exactly the two
///      behaviours the finding depends on:
///        (1) inbound delivery: process() forwards its msg.value into
///            IMessageRecipient.handle{value: msg.value}(...)  (real relayer path)
///        (2) outbound dispatch: dispatch() charges the REAL ProtocolFeeHook as the
///            required post-dispatch hook and reverts on underpayment, exactly like
///            the production Mailbox's requiredHook.postDispatch{value: ...} call.
contract MailboxDouble {
    IPostDispatchHook public requiredHook; // the REAL ProtocolFeeHook
    address public recipient;
    uint256 public dispatchCount;
    bytes32 public latestDispatchedId;

    event Dispatched(uint32 destination, bytes32 recipient, bytes32 id);

    function setRequiredHook(IPostDispatchHook h) external { requiredHook = h; }
    function setRecipient(address r) external { recipient = r; }

    // Hyperlane Mailbox.process(): delivers the message to the recipient, forwarding value.
    function process(
        uint32 origin,
        bytes32 sender,
        bytes calldata data
    ) external payable {
        IMessageRecipient(recipient).handle{value: msg.value}(origin, sender, data);
    }

    // Hyperlane Mailbox.dispatch(): required hook is invoked with the paid value and
    // reverts if the fee is not covered. This is the leg the missing msg.value trips.
    function dispatch(
        uint32 destination,
        bytes32 recipientAddr,
        bytes calldata body
    ) external payable returns (bytes32) {
        requiredHook.postDispatch{value: msg.value}("", body);
        ++dispatchCount;
        bytes32 id = keccak256(abi.encodePacked(destination, recipientAddr, body, dispatchCount));
        latestDispatchedId = id;
        emit Dispatched(destination, recipientAddr, id);
        return id;
    }
}

/// @dev Minimal DIA oracle feed (opaque external price feed boundary).
contract MinimalDIAOracle {
    uint128 public value;
    uint128 public ts;
    function set(uint128 _v, uint128 _t) external { value = _v; ts = _t; }
    function getValue(string memory) external view returns (uint128, uint128) {
        return (value, ts);
    }
}

/// @dev Negative control: the REAL contract with the REAL one-line fix from
///      diadata-org commit 0c4418c ("enable fee for oraclerequestreceipent"),
///      which forwards msg.value into the dispatch call. Everything else is the
///      inherited audited logic. Proves the DoS is caused solely by the missing
///      `{value: msg.value}` on line 76 of the audited OracleRequestRecipient.
contract FixedOracleRequestRecipient is OracleRequestRecipient {
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _data
    ) external payable override nonReentrant {
        require(_data.length > 0, "Invalid data length");
        require(oracleTriggerAddress != address(0), "Oracle trigger address not set");
        require(whitelistedSenders[_origin][_sender], "Sender not whitelisted for this origin");
        address sender = address(uint160(uint256(_sender)));
        require(
            msg.sender == IOracleTrigger(oracleTriggerAddress).getMailBox(),
            "Unauthorized caller"
        );
        string memory key = abi.decode(_data, (string));
        emit ReceivedCall(sender, key);
        // THE FIX: forward msg.value so the outbound dispatch fee is paid.
        IOracleTrigger(oracleTriggerAddress).dispatch{value: msg.value}(_origin, sender, key);
    }
}

contract PoC_55410_FeeDuringInterchainCallback is Test {
    // Hyperlane message parameters for the inbound oracle request.
    uint32 internal constant ORIGIN = 42; // requesting chain domain
    address internal constant REQUEST_ORACLE = address(0xBEEF); // RequestOracle on origin
    string internal constant KEY = "BTC/USD";
    uint256 internal constant GAS_PRICE = 3 gwei; // realistic mainnet-class gas price

    OracleTrigger internal trigger;
    ProtocolFeeHook internal feeHook;
    MailboxDouble internal mailbox;
    MinimalDIAOracle internal oracle;

    OracleRequestRecipient internal buggy; // REAL audited (vulnerable)
    FixedOracleRequestRecipient internal fixedRec; // REAL + real fix

    address internal relayer = makeAddr("relayer");
    bytes32 internal senderB32 = bytes32(uint256(uint160(REQUEST_ORACLE)));
    bytes internal data = abi.encode(KEY);
    uint256 internal fee;

    function setUp() public {
        vm.txGasPrice(GAS_PRICE);

        // --- external boundaries ---
        oracle = new MinimalDIAOracle();
        oracle.set(2000e8, uint128(block.timestamp)); // fresh BTC/USD price
        feeHook = new ProtocolFeeHook(); // REAL audited required fee hook
        mailbox = new MailboxDouble();
        mailbox.setRequiredHook(IPostDispatchHook(address(feeHook)));

        // --- REAL audited Spectra core ---
        trigger = new OracleTrigger(); // deployer (this) holds OWNER_ROLE + admin
        trigger.setMailBox(address(mailbox));
        trigger.updateMetadataContract(address(oracle));

        buggy = new OracleRequestRecipient();
        _configureRecipient(address(buggy));

        fixedRec = new FixedOracleRequestRecipient();
        _configureRecipient(address(fixedRec));

        // fee the honest relayer must attach for the outbound dispatch:
        fee = feeHook.gasUsedPerTx() * GAS_PRICE;
        vm.deal(relayer, 1 ether);
    }

    function _configureRecipient(address rec) internal {
        OracleRequestRecipient(payable(rec)).setOracleTriggerAddress(address(trigger));
        OracleRequestRecipient(payable(rec)).addToWhitelist(ORIGIN, senderB32);
        // In the real deployment the recipient is an owner of the trigger so it may
        // dispatch the response back through the mailbox.
        trigger.addOwner(rec);
    }

    /// @notice HARM: the interchain oracle callback is permanently DoS'd. Even when
    ///         the relayer correctly attaches the full fee to Mailbox.process(), the
    ///         audited handle() drops it before calling OracleTrigger.dispatch(), so
    ///         the outbound dispatch is underpaid and the whole delivery reverts. The
    ///         requested price is NEVER dispatched back to the requesting chain.
    function test_buggyHandle_permanentlyDoSsCallback() public {
        mailbox.setRecipient(address(buggy));
        assertEq(mailbox.dispatchCount(), 0, "precondition");

        // The relayer repeatedly funds delivery correctly; every attempt reverts on
        // the fee hook — a persistent, non-transient DoS (fix requires redeployment).
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(relayer);
            vm.expectRevert(bytes("Insufficient fee paid"));
            mailbox.process{value: fee}(ORIGIN, senderB32, data);
        }

        // No oracle response was ever dispatched back to the origin chain.
        assertEq(mailbox.dispatchCount(), 0, "0 of N requests answered: callback fully DoS'd");
        assertEq(mailbox.latestDispatchedId(), bytes32(0), "no response message produced");
    }

    /// @notice NEGATIVE CONTROL: the real one-line fix (forward msg.value) makes the
    ///         identical, equally-funded flow succeed — the response IS dispatched.
    ///         Proves the harm is caused by the missing value-forward, not the setup.
    function test_fixedHandle_callbackSucceeds() public {
        mailbox.setRecipient(address(fixedRec));
        assertEq(mailbox.dispatchCount(), 0, "precondition");

        vm.prank(relayer);
        mailbox.process{value: fee}(ORIGIN, senderB32, data); // no revert

        assertEq(mailbox.dispatchCount(), 1, "response dispatched back to origin");
        assertTrue(mailbox.latestDispatchedId() != bytes32(0), "response message id produced");
    }

    /// @notice ISOLATION: the missing value forward is the exact and only cause.
    ///         Calling the real OracleTrigger.dispatch with value 0 (as buggy handle
    ///         does) reverts on the fee; with the fee attached it succeeds.
    function test_isolation_missingValueIsTheCause() public {
        // this contract holds OWNER_ROLE (deployer), so it may call dispatch directly.
        vm.expectRevert(bytes("Insufficient fee paid"));
        trigger.dispatch{value: 0}(ORIGIN, REQUEST_ORACLE, KEY);

        uint256 before = mailbox.dispatchCount();
        trigger.dispatch{value: fee}(ORIGIN, REQUEST_ORACLE, KEY);
        assertEq(mailbox.dispatchCount(), before + 1, "same call succeeds once value is forwarded");
    }
}
