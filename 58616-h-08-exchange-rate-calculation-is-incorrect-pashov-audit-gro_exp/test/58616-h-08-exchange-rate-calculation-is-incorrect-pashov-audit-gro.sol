// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq — [H-08] Exchange rate calculation is incorrect
    (Pashov Audit Group, Kinetiq-security-review_2025-02-26, #58616)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: getExchangeRatio mixes LOCAL totalStaked/totalClaimed with
    GLOBAL totalRewards/totalSlashing (ValidatorManager) and GLOBAL kHYPE
    supply. Managers with different local stake compute different rates for
    the same shared token → arbitrage and wrong redemptions.
//////////////////////////////////////////////////////////////////////////*/

contract KHYPE {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

contract ValidatorManager {
    uint256 public totalRewards;
    uint256 public totalSlashing;

    function reportReward(uint256 amount) external {
        totalRewards += amount;
    }
}

contract StakingManager {
    KHYPE public immutable kHYPE;
    ValidatorManager public immutable validatorManager;

    uint256 public totalStaked; // LOCAL
    uint256 public totalClaimed; // LOCAL

    constructor(KHYPE _k, ValidatorManager _vm) {
        kHYPE = _k;
        validatorManager = _vm;
    }

    function getExchangeRatio() public view returns (uint256) {
        uint256 totalSlashing = validatorManager.totalSlashing();
        uint256 totalRewards = validatorManager.totalRewards();
        uint256 kHYPESupply = kHYPE.totalSupply();
        require(kHYPESupply > 0, "No kHYPE supply");

        // Calculate total HYPE: totalStaked + totalRewards - totalClaimed - totalSlashing
        uint256 totalHYPE = totalStaked + totalRewards - totalClaimed - totalSlashing; // @> VULN: LOCAL totalStaked/totalClaimed mixed with GLOBAL rewards/slashing and GLOBAL kHYPE supply
        // FIX: read global stake/claim totals from ValidatorManager

        // Return ratio = totalHYPE / kHYPE.totalSupply (scaled by 1e18)
        return (totalHYPE * 1e18) / kHYPESupply;
    }

    function kHYPEToHYPE(uint256 kAmount) public view returns (uint256) {
        return (kAmount * getExchangeRatio()) / 1e18;
    }

    function stake() external payable {
        require(msg.value > 0, "zero");
        totalStaked += msg.value;
        kHYPE.mint(msg.sender, msg.value);
    }

    function withdraw(uint256 kAmount) external {
        require(kHYPE.balanceOf(msg.sender) >= kAmount, "bal");
        uint256 hypeOut = kHYPEToHYPE(kAmount);
        kHYPE.burn(msg.sender, kAmount);
        totalClaimed += hypeOut;
        (bool ok,) = msg.sender.call{value: hypeOut}("");
        require(ok, "pay");
    }

    function seedLiquidity() external payable {}

    receive() external payable {}
}

contract User {
    function doStake(StakingManager m) external payable {
        m.stake{value: msg.value}();
    }

    function doWithdraw(StakingManager m, uint256 kAmount) external {
        m.withdraw(kAmount);
    }

    receive() external payable {}
}

/// CREATE order: kHYPE (1), vm (2), sm1 (3), sm2 (4), userA (5), userB (6).
contract Exploit {
    KHYPE public kHYPE;
    ValidatorManager public vm;
    StakingManager public sm1;
    StakingManager public sm2;
    User public userA;
    User public userB;

    uint256 public ratioSM1;
    uint256 public ratioSM2;
    uint256 public correctRatio;
    uint256 public arbProfit;

    constructor() {
        kHYPE = new KHYPE(); // 1
        vm = new ValidatorManager(); // 2
        sm1 = new StakingManager(kHYPE, vm); // 3
        sm2 = new StakingManager(kHYPE, vm); // 4
        userA = new User(); // 5
        userB = new User(); // 6
    }

    function run() external payable {
        // SM1: 100, SM2: 100 (matches finding), rewards 20.
        // Buggy ratio each: (100+20)/200 = 0.6e18; correct (200+20)/200 = 1.1e18.
        // Finding arithmetic used local denominator (1.2); production code uses
        // global totalSupply — same root cause, wrong rate either way.
        // Unequal stakes make rates DIVERGE across managers (arbitrage):
        // SM1 50 + SM2 150 + rewards 20 → SM1 (50+20)/200=0.35, SM2 (150+20)/200=0.85, true 1.1
        require(msg.value >= 220 ether, "need 220");

        userA.doStake{value: 50 ether}(sm1);
        userB.doStake{value: 150 ether}(sm2);
        require(kHYPE.totalSupply() == 200 ether, "supply");

        vm.reportReward(20 ether);
        // Liquidity so SM2 can pay its inflated-relative-to-SM1 (still under true) redeem if needed.
        sm2.seedLiquidity{value: 20 ether}();

        ratioSM1 = sm1.getExchangeRatio();
        ratioSM2 = sm2.getExchangeRatio();
        correctRatio = ((200 ether + 20 ether) * 1e18) / 200 ether; // 1.1e18

        require(ratioSM1 == 0.35e18, "sm1 ratio"); // (50+20)/200
        require(ratioSM2 == 0.85e18, "sm2 ratio"); // (150+20)/200
        require(correctRatio == 1.1e18, "correct");
        require(ratioSM1 != ratioSM2, "managers disagree");
        require(ratioSM1 != correctRatio && ratioSM2 != correctRatio, "both wrong");

        // Arbitrage sketch: buy/mint via high-rate manager relative path is complex;
        // concrete harm: redeeming 50 kHYPE via SM1 pays 17.5 vs fair 55 → user shortchanged 37.5.
        uint256 paid = sm1.kHYPEToHYPE(50 ether);
        uint256 fair = (50 ether * correctRatio) / 1e18;
        require(paid == 17.5 ether, "paid 17.5");
        require(fair == 55 ether, "fair 55");
        arbProfit = fair - paid; // value extracted from / denied to staker
        require(arbProfit == 37.5 ether, "harm not demonstrated");
    }

    receive() external payable {}
}
