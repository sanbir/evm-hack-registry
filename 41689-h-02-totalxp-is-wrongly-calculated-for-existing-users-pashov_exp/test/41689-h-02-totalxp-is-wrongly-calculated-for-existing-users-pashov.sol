// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DYAD DyadXPv2 — initialize copies lastXP and drops the elapsed bonus
    (Pashov, Dyad security review, H-02).

    SYNTHETIC, cheatcode-free reduction. The replay block timestamp is 1
    and the note's lastAction is 0, so one second of the audited formula
    is due. lastXP is 1e18. _computeXP returns 1e18 + 1e25. initialize
    stores lastXP. A position reward equal to that XP pays 1e18 instead
    of the fair 1e18 + 1e25. The control stores _computeXP. */

struct NoteXPData {
    uint40 lastAction;
    uint96 keroseneDeposited;
    uint256 lastXP;
    uint256 totalXP;
    uint256 dyadMinted;
}

library Wad {
    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / 1e18;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18) / y;
    }

    function log10(uint256 x) internal pure returns (uint256 r) {
        require(x > 0, "log");
        while (x >= 10) {
            x /= 10;
            unchecked {
                r++;
            }
        }
    }
}

contract MockXP {
    string public name = "Note XP";
    string public symbol = "XP";
    uint8 public decimals = 0;
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

contract MockKerosene {
    function id2asset(uint256) external pure returns (uint256) {
        return 1e18;
    }
}

contract MockDyad {
    function mintedDyad(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract DyadXPv2 {
    using Wad for uint256;

    MockXP public xpToken;
    MockKerosene public kerosene;
    MockDyad public dyad;
    mapping(uint256 => NoteXPData) public noteData;
    bool public initialized;

    constructor(address _xp, address _kerosene, address _dyad) {
        xpToken = MockXP(_xp);
        kerosene = MockKerosene(_kerosene);
        dyad = MockDyad(_dyad);
    }

    function seedExisting(uint256 id) external {
        noteData[id] = NoteXPData({
            lastAction: 0,
            keroseneDeposited: uint96(1e18),
            lastXP: 1e18,
            totalXP: 0,
            dyadMinted: 0
        });
    }

    function initialize() external virtual {
        require(!initialized, "init");
        initialized = true;
        uint256 dnftSupply = 1;
        for (uint256 i = 0; i < dnftSupply; ++i) {
            // @> VULN: totalXP copies lastXP and drops the elapsed bonus
            noteData[i] = NoteXPData({
                lastAction: uint40(block.timestamp),
                keroseneDeposited: uint96(kerosene.id2asset(i)),
                lastXP: noteData[i].lastXP,
                totalXP: noteData[i].lastXP,
                dyadMinted: dyad.mintedDyad(i)
            });
        }
    }

    function _computeXP(NoteXPData memory lastUpdate) public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdate.lastAction;
        uint256 deposited = lastUpdate.keroseneDeposited;
        uint256 dyadMinted = lastUpdate.dyadMinted;
        uint256 totalXP = lastUpdate.totalXP;
        uint256 accrualRateModifier = totalXP > 0 ? 1e18 / totalXP.log10() : 1e18;
        uint256 adjustedAccrualRate = accrualRateModifier * 1e7;
        uint256 bonus = deposited;
        if (dyadMinted + deposited != 0) {
            bonus += deposited.mulWadDown(dyadMinted.divWadDown(dyadMinted + deposited));
        }
        return uint256(lastUpdate.lastXP + (elapsed * adjustedAccrualRate * bonus) / 1e18);
    }

    /// Position reward from the audited shape timeDiff * rewardsRate * liquidity * xp.
    function claimPositionReward(uint256 id, address to) external {
        uint256 xp = noteData[id].totalXP;
        uint256 timeDiff = 1;
        uint256 rewardsRate = 1;
        uint256 liquidity = 1;
        uint256 rewards = timeDiff * rewardsRate * liquidity * xp;
        require(xpToken.transfer(to, rewards), "reward");
    }
}

contract DyadXPv2Fixed is DyadXPv2 {
    constructor(address _xp, address _kerosene, address _dyad) DyadXPv2(_xp, _kerosene, _dyad) {}

    function initialize() external override {
        require(!initialized, "init");
        initialized = true;
        uint256 dnftSupply = 1;
        for (uint256 i = 0; i < dnftSupply; ++i) {
            // FIX: credit the elapsed bonus, not only lastXP
            uint256 totalXP = _computeXP(noteData[i]);
            noteData[i] = NoteXPData({
                lastAction: uint40(block.timestamp),
                keroseneDeposited: uint96(kerosene.id2asset(i)),
                lastXP: noteData[i].lastXP,
                totalXP: totalXP,
                dyadMinted: dyad.mintedDyad(i)
            });
        }
    }
}

contract Exploit {
    uint256 public constant LAST_XP = 1e18;
    uint256 public constant FAIR_XP = 10000001000000000000000000;
    uint256 public constant SHORTFALL = 10000000000000000000000000;

    MockXP public xpToken; // nonce 1
    MockKerosene public kerosene; // nonce 2
    MockDyad public dyad; // nonce 3
    DyadXPv2 public xp; // nonce 4

    uint256 public fairXP;
    uint256 public credited;
    uint256 public rewardPaid;
    uint256 public unpaid;

    constructor() {
        xpToken = new MockXP();
        kerosene = new MockKerosene();
        dyad = new MockDyad();
        xp = new DyadXPv2(address(xpToken), address(kerosene), address(dyad));
    }

    function run() external {
        xp.seedExisting(0);
        fairXP = xp._computeXP(xpNote());
        require(fairXP == FAIR_XP, "fair");
        require(block.timestamp == 1, "timestamp");
        xpToken.mint(address(xp), fairXP);
        xp.initialize();
        credited = xpTotal();
        require(credited == LAST_XP, "credited");
        xp.claimPositionReward(0, address(this));
        rewardPaid = xpToken.balanceOf(address(this));
        unpaid = xpToken.balanceOf(address(xp));
        require(rewardPaid == credited, "reward");
        require(unpaid == SHORTFALL, "unpaid");
        require(fairXP - credited == SHORTFALL, "gap");
    }

    function xpNote() public view returns (NoteXPData memory data) {
        (data.lastAction, data.keroseneDeposited, data.lastXP, data.totalXP, data.dyadMinted) = xp.noteData(0);
    }

    function xpTotal() public view returns (uint256 total) {
        (,,, total,) = xp.noteData(0);
    }
}
