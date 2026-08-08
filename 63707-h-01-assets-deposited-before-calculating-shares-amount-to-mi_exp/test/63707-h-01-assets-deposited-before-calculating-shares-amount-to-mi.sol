// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Hybra Finance — Assets deposited before calculating shares to mint
    (Code4rena 2025-10-hybra-finance, finding #63707)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: GovernanceHYBR.deposit first deposits HYBR into votingEscrow
    (increasing totalAssets), then calculates shares with the inflated total.
    Second depositor is treated as if their deposit were rewards and mints
    fewer shares (e.g. 50 instead of 100 at 1:1). Vulnerable order preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Minimal voting escrow that holds HYBR and reports locked balance as totalAssets source.
contract MockVotingEscrow {
    MockERC20 public immutable hybr;
    mapping(uint256 => uint256) public locked; // veTokenId => amount
    uint256 public nextId = 1;
    uint256 public totalLocked;

    constructor(MockERC20 _hybr) {
        hybr = _hybr;
    }

    function create_lock(uint256 amount, uint256 /*unlockTime*/) external returns (uint256 id) {
        hybr.transferFrom(msg.sender, address(this), amount);
        id = nextId++;
        locked[id] = amount;
        totalLocked += amount;
    }

    function deposit_for(uint256 veTokenId, uint256 amount) external {
        hybr.transferFrom(msg.sender, address(this), amount);
        locked[veTokenId] += amount;
        totalLocked += amount;
    }
}

/// @notice Reduced GovernanceHYBR: deposit into ve then mint shares from inflated totalAssets.
/// Source: GovernanceHYBR.sol L137-L144 (code-423n4/2025-10-hybra-finance commit 66c42f3).
contract GovernanceHYBR {
    MockERC20 public immutable HYBR;
    MockVotingEscrow public immutable votingEscrow;
    uint256 public veTokenId;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(MockERC20 _hybr, MockVotingEscrow _ve) {
        HYBR = _hybr;
        votingEscrow = _ve;
    }

    function totalAssets() public view returns (uint256) {
        if (veTokenId == 0) return 0;
        return votingEscrow.locked(veTokenId);
    }

    function calculateShares(uint256 amount) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return amount;
        uint256 assets = totalAssets();
        if (assets == 0) return amount;
        return (amount * supply) / assets;
    }

    function deposit(uint256 amount, address recipient) external {
        require(amount > 0, "amt");
        HYBR.transferFrom(msg.sender, address(this), amount);

        if (veTokenId == 0) {
            HYBR.approve(address(votingEscrow), amount);
            veTokenId = votingEscrow.create_lock(amount, 0);
        } else {
            // Add to existing veNFT
            HYBR.approve(address(votingEscrow), amount);
            votingEscrow.deposit_for(veTokenId, amount);
            // Extend lock omitted
        }

        // FIX: calculate shares BEFORE deposit_for / create_lock so totalAssets excludes this deposit
        uint256 shares = calculateShares(amount); // @> VULN: shares calculated AFTER deposit increased totalAssets

        // Mint gHYBR shares
        _mint(recipient, shares);
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

/// @dev Second depositor actor.
contract Depositor {
    function approve(MockERC20 t, address spender, uint256 amt) external {
        t.approve(spender, amt);
    }

    function deposit(GovernanceHYBR g, uint256 amt) external {
        g.deposit(amt, address(this));
    }
}

/// @notice Alice deposits after Bob and receives half the shares she should.
/// CREATE order: hybr (1), ve (2), gHybr (3), alice (4). Bob = Exploit.
contract Exploit {
    MockERC20 public hybr;
    MockVotingEscrow public ve;
    GovernanceHYBR public gHybr;
    Depositor public alice;

    uint256 public bobShares;
    uint256 public aliceShares;

    constructor() {
        hybr = new MockERC20("HYBR", "HYBR"); // 1
        ve = new MockVotingEscrow(hybr); // 2
        gHybr = new GovernanceHYBR(hybr, ve); // 3
        alice = new Depositor(); // 4
    }

    function run() external {
        hybr.mint(address(this), 100e18);
        hybr.mint(address(alice), 100e18);

        // Bob deposits 100 at 1:1
        hybr.approve(address(gHybr), 100e18);
        gHybr.deposit(100e18, address(this));
        bobShares = gHybr.balanceOf(address(this));
        require(bobShares == 100e18, "bob 1:1");

        // Alice deposits 100 — should get 100 shares at 1:1, but deposit-before-calc mints 50
        alice.approve(hybr, address(gHybr), 100e18);
        alice.deposit(gHybr, 100e18);
        aliceShares = gHybr.balanceOf(address(alice));

        // Harm: Alice minted fewer shares than Bob for the same deposit; own assets caused slippage
        require(aliceShares < bobShares, "alice under-minted");
        require(aliceShares == 50e18, "alice got half shares");
        require(gHybr.totalAssets() == 200e18, "assets doubled");
        // Alice owns 50/150 of 200 assets = 66.67, so ~33 loss vs fair 100
        uint256 aliceAssets = (aliceShares * gHybr.totalAssets()) / gHybr.totalSupply();
        require(aliceAssets < 100e18, "alice lost assets");
        require(aliceAssets <= 70e18, "meaningful loss");
    }
}
