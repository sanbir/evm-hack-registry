// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Entangle Trillion — Curve/Convex withdrawals are blocked by a misspelled selector (Halborn, #51369). */
contract MockLP {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RealConvex {
    MockLP public immutable lp;
    constructor(MockLP _lp) { lp = _lp; }
    function withdraw(uint256, uint256 amount) external returns (bool) {
        return lp.transfer(msg.sender, amount);
    }
}

interface IConvexWithTypo { function witdraw(uint256 pid, uint256 amount) external returns (bool); }

contract CurveCompoundConvexSynthChef {
    struct Pool { uint256 convexID; MockLP lp; }
    mapping(uint32 => Pool) public pools;
    address public immutable masterChef;
    IConvexWithTypo public immutable convex;
    error CurveCompoundConvexSynthChef__E4();

    constructor(address _masterChef, IConvexWithTypo _convex) { masterChef = _masterChef; convex = _convex; }
    modifier onlyMaster() { require(msg.sender == masterChef, "master"); _; }
    function addPool(uint32 poolId, uint256 convexId, MockLP lp) external onlyMaster { pools[poolId] = Pool(convexId, lp); }

    /// @notice Withdraw LP tokens from farm and transfer it to entangle MasterChef. Can only be called by the MASTER.
    /// @param poolId Entangle internal poolId.
    /// @param lpAmount Amount of LP tokens to withdraw.
    function withdrawLP(uint32 poolId, uint256 lpAmount) external onlyMaster {
        Pool memory pool = pools[poolId];
        bool suc = convex.witdraw(pool.convexID, lpAmount); // @> VULN: Convex exposes withdraw(), not witdraw().
        // FIX: call convex.withdraw(pool.convexID, lpAmount).
        if (!suc) revert CurveCompoundConvexSynthChef__E4();
        require(pool.lp.transfer(masterChef, lpAmount), "LP transfer");
    }
}

contract Exploit {
    MockLP public lp; // CREATE nonce 1
    RealConvex public realConvex; // CREATE nonce 2
    CurveCompoundConvexSynthChef public chef; // CREATE nonce 3 (vulnerable)
    bool public withdrawalBlocked;

    constructor() {
        lp = new MockLP();
        realConvex = new RealConvex(lp);
        chef = new CurveCompoundConvexSynthChef(address(this), IConvexWithTypo(address(realConvex)));
        chef.addPool(7, 44, lp);
        lp.mint(address(chef), 100);
    }

    function run() external {
        try chef.withdrawLP(7, 100) { withdrawalBlocked = false; } catch { withdrawalBlocked = true; }
        require(withdrawalBlocked, "wrong selector unexpectedly succeeded");
        require(lp.balanceOf(address(chef)) == 100, "LP was not stuck");
        require(lp.balanceOf(address(this)) == 0, "master unexpectedly received LP");
    }
}