// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DYAD H-01 - DyadXPv2._computeXP (Pashov, DyadStablecoin/contracts).
    The documented base accrual scale is 1e9. The function multiplies the
    modifier by 1e7, so a note whose totalXP is still 0 - the base-rate case  - 
    is credited 1/100 of the XP the docs describe. On this model chain the
    clock is 1 and the note's lastAction is 0, so the window is 1 second on
    1 kerosene: 10_000_000 XP instead of 1_000_000_000 XP.
*/

contract XpToken {
    string public symbol = "XP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract DyadXPv2 {
    struct NoteXPData {
        uint40 lastAction;
        uint96 keroseneDeposited;
        uint256 lastXP;
        uint256 totalXP;
        uint256 dyadMinted;
    }

    XpToken public immutable xpToken;
    mapping(uint256 => NoteXPData) public notes;
    mapping(uint256 => address) public owners;

    constructor(XpToken token) {
        xpToken = token;
    }

    function seed(uint256 noteId, address owner, uint256 deposited) external {
        notes[noteId] = NoteXPData({
            lastAction: 0,
            keroseneDeposited: uint96(deposited),
            lastXP: 0,
            totalXP: 0,
            dyadMinted: 0
        });
        owners[noteId] = owner;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18) / y;
    }

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / 1e18;
    }

    function _computeXP(NoteXPData memory lastUpdate) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdate.lastAction;
        uint256 deposited = lastUpdate.keroseneDeposited;
        uint256 dyadMinted = lastUpdate.dyadMinted;
        uint256 totalXP = lastUpdate.totalXP;

        // totalXP == 0 is the documented base rate: modifier 1e18, not 1e18/log10.
        uint256 accrualRateModifier = 1e18;
        if (totalXP > 0) {
            revert("base-rate note");
        }

        // @> VULN: documented base accrual scale is 1e9; 1e7 pays 1/100 of that XP
        uint256 adjustedAccrualRate = accrualRateModifier * 1e7; // @> VULN: base scale is 1e7, not 1e9

        uint256 bonus = deposited;
        if (dyadMinted + deposited != 0) {
            uint256 ratio = divWadDown(dyadMinted, dyadMinted + deposited);
            bonus += mulWadDown(deposited, ratio);
        }

        return lastUpdate.lastXP + (elapsed * adjustedAccrualRate * bonus) / 1e18;
    }

    function accrue(uint256 noteId) external returns (uint256 xp) {
        NoteXPData memory lastUpdate = notes[noteId];
        xp = _computeXP(lastUpdate);
        uint256 minted = xp - lastUpdate.lastXP;
        notes[noteId].lastXP = xp;
        notes[noteId].totalXP = xp;
        notes[noteId].lastAction = uint40(block.timestamp);
        xpToken.mint(owners[noteId], minted);
    }
}

contract DyadXPv2Fixed {
    struct NoteXPData {
        uint40 lastAction;
        uint96 keroseneDeposited;
        uint256 lastXP;
        uint256 totalXP;
        uint256 dyadMinted;
    }

    XpToken public immutable xpToken;
    mapping(uint256 => NoteXPData) public notes;
    mapping(uint256 => address) public owners;

    constructor(XpToken token) {
        xpToken = token;
    }

    function seed(uint256 noteId, address owner, uint256 deposited) external {
        notes[noteId] = NoteXPData({
            lastAction: 0,
            keroseneDeposited: uint96(deposited),
            lastXP: 0,
            totalXP: 0,
            dyadMinted: 0
        });
        owners[noteId] = owner;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18) / y;
    }

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / 1e18;
    }

    function _computeXP(NoteXPData memory lastUpdate) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdate.lastAction;
        uint256 deposited = lastUpdate.keroseneDeposited;
        uint256 dyadMinted = lastUpdate.dyadMinted;
        uint256 totalXP = lastUpdate.totalXP;
        uint256 accrualRateModifier = 1e18;
        if (totalXP > 0) {
            revert("base-rate note");
        }
        uint256 adjustedAccrualRate = accrualRateModifier * 1e9;
        uint256 bonus = deposited;
        if (dyadMinted + deposited != 0) {
            uint256 ratio = divWadDown(dyadMinted, dyadMinted + deposited);
            bonus += mulWadDown(deposited, ratio);
        }
        return lastUpdate.lastXP + (elapsed * adjustedAccrualRate * bonus) / 1e18;
    }

    function accrue(uint256 noteId) external returns (uint256 xp) {
        NoteXPData memory lastUpdate = notes[noteId];
        xp = _computeXP(lastUpdate);
        uint256 minted = xp - lastUpdate.lastXP;
        xpToken.mint(owners[noteId], minted);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1 ether;
    uint256 public constant BUGGY = 10_000_000 ether;
    uint256 public constant FAIR = 1_000_000_000 ether;

    XpToken public xp;
    DyadXPv2 public book;
    uint256 public paid;

    constructor() {
        xp = new XpToken();
        book = new DyadXPv2(xp);
        book.seed(1, address(this), DEPOSIT);
    }

    function run() external {
        paid = book.accrue(1);
        require(block.timestamp == 1, "clock");
        require(paid == BUGGY, "credited");
        require(paid * 100 == FAIR, "one hundredth");
        require(xp.balanceOf(address(this)) == paid, "balance");
    }
}
