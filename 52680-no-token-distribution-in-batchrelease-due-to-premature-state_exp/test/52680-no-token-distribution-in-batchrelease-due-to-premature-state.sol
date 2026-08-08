// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Treasury Vesting (BlockDAG) — batchRelease updates state then re-reads releasable=0
    (Halborn, finding #52680)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: batchRelease splits "effects" and "interactions" into two loops.
    Loop 1 credits userReleased / category.released; loop 2 calls
    getReleasableAmount again, which now returns 0, so no tokens are transferred.
    Accounting says funds were released; users receive nothing. @> VULN on loop-2 re-read. */

contract MockBDAG {
    string public constant name = "BDAG";
    string public constant symbol = "BDAG";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract TreasuryVesting {
    bytes32 public constant EARLY_BIRD_CATEGORY = keccak256("EARLY_BIRD");

    struct CategoryVesting {
        uint256 released;
    }

    MockBDAG public immutable bdagToken;
    address public admin;
    mapping(address => mapping(bytes32 => uint256)) public allocation;
    mapping(address => mapping(bytes32 => uint256)) public userReleased;
    mapping(bytes32 => CategoryVesting) public categoryVestings;
    uint256 public totalReleased;

    constructor(MockBDAG token_) {
        bdagToken = token_;
        admin = msg.sender;
    }

    function allocateTokens(address user, bytes32 category, uint256 amount) external {
        require(msg.sender == admin, "admin");
        allocation[user][category] += amount;
    }

    /// @dev Fully vested immediately (cliff/schedule orthogonal to the bug).
    function getReleasableAmount(address user, bytes32 category) public view returns (uint256) {
        uint256 alloc = allocation[user][category];
        uint256 already = userReleased[user][category];
        if (alloc <= already) return 0;
        return alloc - already;
    }

    /// @dev Current (buggy) implementation: two loops — effects then interactions.
    function batchRelease(bytes32 category, address[] calldata users) external {
        require(msg.sender == admin, "admin");
        require(users.length > 0, "Empty users array");

        // First loop: Updates state
        for (uint256 i = 0; i < users.length; i++) {
            uint256 releasable = getReleasableAmount(users[i], category); // Returns X tokens
            if (releasable > 0) {
                userReleased[users[i]][category] += releasable; // Updates state
                categoryVestings[category].released += releasable;
                totalReleased += releasable;
            }
        }

        // Second loop: Attempts transfers
        for (uint256 i = 0; i < users.length; i++) {
            uint256 releasable = getReleasableAmount(users[i], category); // @> VULN: returns 0 because state was updated in loop 1 — transfers never fire
            // FIX: transfer inside the first loop (or cache releasable amounts) before/when updating state
            if (releasable > 0) {
                // This condition is never true after loop 1
                bdagToken.transferFrom(msg.sender, users[i], releasable);
            }
        }
    }
}

contract UserTag {
    // empty marker addresses via CREATE
}

contract Exploit {
    MockBDAG public token; // CREATE nonce 1
    TreasuryVesting public vesting; // CREATE nonce 2 — vulnerable
    UserTag public user1; // CREATE nonce 3
    UserTag public user2; // CREATE nonce 4

    uint256 public constant U1 = 1000 ether;
    uint256 public constant U2 = 2000 ether;

    constructor() {
        token = new MockBDAG();
        vesting = new TreasuryVesting(token);
        user1 = new UserTag();
        user2 = new UserTag();

        vesting.allocateTokens(address(user1), vesting.EARLY_BIRD_CATEGORY(), U1);
        vesting.allocateTokens(address(user2), vesting.EARLY_BIRD_CATEGORY(), U2);

        // Admin (this) holds tokens + approval for the intended transferFrom path.
        token.mint(address(this), U1 + U2);
        token.approve(address(vesting), U1 + U2);
    }

    function run() external {
        address[] memory users = new address[](2);
        users[0] = address(user1);
        users[1] = address(user2);

        uint256 u1Before = token.balanceOf(address(user1));
        uint256 u2Before = token.balanceOf(address(user2));
        uint256 adminBefore = token.balanceOf(address(this));

        vesting.batchRelease(vesting.EARLY_BIRD_CATEGORY(), users);

        // HARM: accounting claims full release, but users received nothing.
        require(vesting.totalReleased() == U1 + U2, "accounting says released");
        require(
            vesting.userReleased(address(user1), vesting.EARLY_BIRD_CATEGORY()) == U1,
            "user1 marked released"
        );
        require(
            vesting.userReleased(address(user2), vesting.EARLY_BIRD_CATEGORY()) == U2,
            "user2 marked released"
        );
        require(token.balanceOf(address(user1)) == u1Before, "user1 got tokens (should not)");
        require(token.balanceOf(address(user2)) == u2Before, "user2 got tokens (should not)");
        require(token.balanceOf(address(this)) == adminBefore, "admin inventory unchanged");
        // Users are now permanently blocked: getReleasableAmount returns 0 forever.
        require(vesting.getReleasableAmount(address(user1), vesting.EARLY_BIRD_CATEGORY()) == 0, "u1 stuck");
        require(vesting.getReleasableAmount(address(user2), vesting.EARLY_BIRD_CATEGORY()) == 0, "u2 stuck");
    }
}
