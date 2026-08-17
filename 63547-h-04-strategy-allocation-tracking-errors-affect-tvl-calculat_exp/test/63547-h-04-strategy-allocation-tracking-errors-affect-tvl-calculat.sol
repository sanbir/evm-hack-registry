// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63547 (H-04):
// "Strategy allocation tracking errors affect TVL calculations".
//
// Real audited source (the vulnerable accounting is reproduced VERBATIM from the
// finding's embedded solidity block; the vulnerable line is marked @>):
//   protocol  Elytra
//   auditor   Pashov Audit Group
//   report    github.com/pashov/audits/blob/master/team/md/
//             Elytra-security-review_2025-07-10.md   (finding [H-04])
//   src       embedded (the finding quotes the audited getTotalAssetTVL view
//             plus the allocation `+= amount` and the deallocation if/else block)
//
// Root cause: the protocol tracks strategy holdings with a STATIC storage
// counter `assetsAllocatedToStrategies[asset]` that is only bumped on allocate
// (`+= amount`) and decremented on deallocate by the *tokens actually withdrawn*
// (`-= withdrawn`, the @> line). It never reconciles against the strategy's real
// balance, so yield that grows inside the strategy is invisible to the counter.
// `getTotalAssetTVL()` sums that stale counter, so reported TVL drifts away from
// the assets the protocol truly controls — mispricing `elyAsset`.
//
// Finding's own worked example (reproduced here VERBATIM in numbers):
//   allocate 100  -> counter = 100, strategy holds 100
//   strategy yields +20 -> strategy holds 120 (counter still 100)
//   deallocate 60 -> withdrawn = 60, counter -= 60 => 40, strategy holds 60
//   getTotalAssetTVL = pool(60) + counter(40) = 100   [reported]
//   real holdings    = pool(60) + strategy(60) = 120   [actual]
//   => TVL under-reported by 20 (the un-credited yield still in the strategy),
//      the counter SHOULD read 60 but reads 40.
//
// The vulnerable statements (getTotalAssetTVL, `assetsAllocatedToStrategies +=`,
// the deallocation if/else) are byte-for-byte the finding's embedded source.
// Non-vulnerable dependencies (the ERC20 asset, the strategy's deposit/withdraw/
// balanceOf, the unstaking-vault view) are faithful minimal doubles that move
// real tokens and hold real balances — no fake constants.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Faithful minimal ERC20 double for the pooled asset (finding uses USDC, 6dp).
contract USDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IElytraStrategy {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
    function balanceOf(address asset) external view returns (uint256);
}

/// @dev Faithful double of an Elytra restaking strategy. It holds REAL asset
///      tokens; `deposit` records the transferred principal, `withdraw` pays the
///      requested amount (capped at its real balance) back to the vault and
///      returns the amount actually paid, and `balanceOf` reflects the strategy's
///      genuine on-chain token balance (which grows as yield accrues).
contract ElytraStrategy is IElytraStrategy {
    function deposit(address, /*asset*/ uint256 /*amount*/ ) external {
        // principal was transferred in by the vault before deposit(); nothing to
        // pull here. Real tokens already sit in this contract.
    }

    function withdraw(address asset, uint256 amount) external returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 amt = amount > bal ? bal : amount;
        IERC20(asset).transfer(msg.sender, amt);
        return amt;
    }

    function balanceOf(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the asset-TVL accounting is reproduced VERBATIM from the
// Elytra finding's embedded source.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraAssetVault {
    // Static, manually-maintained tracker of strategy allocations (the bug).
    mapping(address => uint256) public assetsAllocatedToStrategies;

    // VERBATIM from the finding: TVL = pool balance + static tracker + unstaking.
    function getTotalAssetTVL(address asset) public view returns (uint256 totalTVL) {
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        uint256 strategyAllocated = assetsAllocatedToStrategies[asset];
        uint256 unstakingVaultBalance = _getUnstakingVaultBalance(asset);

        return poolBalance + strategyAllocated + unstakingVaultBalance;
    }

    /// @notice Allocate `amount` of `asset` into `strategy`.
    ///         The tracker bump is VERBATIM from the finding.
    function allocateToStrategy(address asset, address strategy, uint256 amount) external {
        IERC20(asset).transfer(strategy, amount);
        IElytraStrategy(strategy).deposit(asset, amount);

        // Called during allocation
        assetsAllocatedToStrategies[asset] += amount;
    }

    /// @notice Deallocate `amount` of `asset` from `strategy`.
    ///         The if/else tracker update is VERBATIM from the finding.
    function deallocateFromStrategy(address asset, address strategy, uint256 amount) external {
        // Called during deallocation
        uint256 withdrawn = IElytraStrategy(strategy).withdraw(asset, amount);
        if (withdrawn <= assetsAllocatedToStrategies[asset]) {
            assetsAllocatedToStrategies[asset] -= withdrawn; // @> VULN: tracker decremented by tokens withdrawn, never reconciled to the strategy's real balance, so in-strategy yield/P&L is silently dropped from getTotalAssetTVL
        } else {
            assetsAllocatedToStrategies[asset] = 0;
        }
    }

    /// @dev Faithful double: no pending unstakes in this scenario.
    function _getUnstakingVaultBalance(address /*asset*/ ) internal pure returns (uint256) {
        return 0;
    }
}

/// @dev 6-decimal marker token used to record the silent integrity loss (the TVL
///      gap) at the SINK address — the harm has no positive transfer to any
///      attacker, so its magnitude is minted to SINK per the accounting-harm
///      convention.
contract MarkerToken {
    string public name = "Elytra TVL Gap Marker";
    string public symbol = "TVL-GAP";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: walk the finding's worked example and prove getTotalAssetTVL
// diverges from the protocol's real holdings after strategy yield + a partial
// deallocation. The un-credited yield (TVL gap) is marked at SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SEED = 100e6; // depositors' 100 USDC in the vault
    uint256 internal constant YIELD = 20e6; //  strategy yields +20 USDC
    uint256 internal constant DEALLOC = 60e6; // operator deallocates 60 USDC

    USDC public usdc;
    ElytraStrategy public strategy;
    ElytraAssetVault public vuln;
    MarkerToken public marker;

    uint256 public reportedTVL; // getTotalAssetTVL() — what the protocol believes
    uint256 public actualHoldings; // pool + real strategy balance — the truth
    uint256 public trackerAfter; // assetsAllocatedToStrategies (stale)
    uint256 public strategyRealAfter; // strategy.balanceOf (real)
    uint256 public tvlGap; // actualHoldings - reportedTVL (integrity loss)

    constructor() {
        usdc = new USDC(); // child nonce 1
        strategy = new ElytraStrategy(); // child nonce 2
        vuln = new ElytraAssetVault(); // child nonce 3 (VULN)
        marker = new MarkerToken(); // child nonce 4 (marker)
    }

    function run() external {
        address asset = address(usdc);

        // depositors fund the vault with 100 USDC
        usdc.mint(address(vuln), SEED);

        // 1) allocate 100 -> tracker = 100, strategy holds 100, pool = 0
        vuln.allocateToStrategy(asset, address(strategy), SEED);

        // 2) strategy accrues +20 yield (real tokens flow into the strategy)
        usdc.mint(address(strategy), YIELD);

        // 3) deallocate 60 -> withdrawn = 60, tracker -= 60 => 40,
        //    strategy holds 120 - 60 = 60, pool = 60
        vuln.deallocateFromStrategy(asset, address(strategy), DEALLOC);

        // ---- read the stale accounting vs the truth ----
        trackerAfter = vuln.assetsAllocatedToStrategies(asset); // 40 (should be 60)
        strategyRealAfter = strategy.balanceOf(asset); // 60 (real)
        reportedTVL = vuln.getTotalAssetTVL(asset); // pool(60) + tracker(40) = 100
        actualHoldings = usdc.balanceOf(address(vuln)) + strategyRealAfter; // 60 + 60 = 120

        // the tracker under-reports the strategy's real balance by the yield
        require(trackerAfter == 40e6, "unexpected tracker");
        require(strategyRealAfter == 60e6, "unexpected strategy balance");
        require(trackerAfter < strategyRealAfter, "tracker not understated");

        // getTotalAssetTVL therefore diverges from real holdings
        require(reportedTVL == 100e6, "unexpected reported TVL");
        require(actualHoldings == 120e6, "unexpected actual holdings");
        require(reportedTVL < actualHoldings, "no TVL drift");

        // HARM: TVL is mispriced by the full un-credited yield -> elyAsset deflated
        tvlGap = actualHoldings - reportedTVL;
        require(tvlGap == YIELD, "TVL gap != un-credited yield");

        // mark the silent integrity loss at SINK
        marker.mint(SINK, tvlGap);
        require(marker.balanceOf(SINK) == YIELD, "sink not marked");
    }
}
