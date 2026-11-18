// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Dumont MontRewardManager — MONT reward is capped by a USDT amount
    (Pashov, finding #38014)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: reward is 18-decimal MONT and _totalAmount is 6-decimal USDT.
    The comparison stores the USDT figure as the MONT credit. The report's
    reveal logs 5_000e18 expected and 11_800_000 paid. */

contract MONT {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
}

contract MontRewardManager {
    MONT public mont;
    uint256 public uncapped;
    uint256 public paid;
    mapping(address => uint256) public balances;

    constructor(MONT mont_) {
        mont = mont_;
    }

    function getMontPrice() public pure returns (uint256 price) {
        price = 8;
    }

    function calculateHouseFee(uint256 betAmount, uint256 houseEdgeAmount, bool isPlayerWinner)
        public
        pure
        returns (uint256)
    {
        if (isPlayerWinner) return houseEdgeAmount;
        return betAmount / 10;
    }

    function transferPlayerRewards(
        address player,
        uint256 betAmount,
        uint256 totalAmount,
        uint256 houseEdgeAmount,
        bool isPlayerWinner
    ) external returns (uint256 reward) {
        uint256 houseFee = calculateHouseFee(betAmount, houseEdgeAmount, isPlayerWinner);
        uint256 price = getMontPrice();
        uint256 houseFeeFixedPoint = houseFee * 1e18;
        reward = ((houseFeeFixedPoint * 8) / 10) / price;
        uncapped = reward;
        if (reward > totalAmount) {
            reward = totalAmount; // @> VULN: 18-decimal MONT is replaced by the 6-decimal USDT total
            // FIX: delete the cap, or scale totalAmount by 1e12 before comparing
        }
        balances[player] += reward;
        mont.mint(player, reward);
        paid = reward;
    }

    function transferUncapped(
        address player,
        uint256 betAmount,
        uint256 houseEdgeAmount,
        bool isPlayerWinner
    ) external returns (uint256 reward) {
        uint256 houseFee = calculateHouseFee(betAmount, houseEdgeAmount, isPlayerWinner);
        uint256 price = getMontPrice();
        uint256 houseFeeFixedPoint = houseFee * 1e18;
        reward = ((houseFeeFixedPoint * 8) / 10) / price;
        balances[player] += reward;
        mont.mint(player, reward);
    }
}

contract Exploit {
    MONT public mont;
    MontRewardManager public manager;
    uint256 public paid;
    uint256 public uncapped;
    uint256 public fair;

    constructor() {
        mont = new MONT();
        manager = new MontRewardManager(mont);
    }

    function run() external {
        address player = msg.sender;
        paid = manager.transferPlayerRewards(player, 1_000_000, 11_800_000, 50_000, true);
        uncapped = manager.uncapped();
        fair = manager.transferUncapped(address(0xC0FFEE), 1_000_000, 50_000, true);
        require(uncapped == 5000 ether, "expected");
        require(paid == 11_800_000, "capped");
        require(mont.balanceOf(player) == 11_800_000, "player");
        require(fair == 5000 ether, "control");
        require(paid < uncapped, "short");
    }
}
