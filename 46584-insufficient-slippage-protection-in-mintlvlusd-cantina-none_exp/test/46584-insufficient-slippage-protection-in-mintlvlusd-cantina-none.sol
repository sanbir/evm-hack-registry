// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Level — mintlvlUSD overwrites the slippage minimum
    (Cantina / Mario Poneder, finding #46584, October 2024)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The minimum lvlUSD out is supposed to be the quote minus
    maxSlippageThresholdBasisPoints (5 bps). The code assigns the
    5 bps slice itself, so the floor collapses from 999.5 to 0.5.
    A mint fill at that floor pays the minter 0.5 lvlUSD for 1,000
    collateral. The stated minimum is 999.5.

    The assignment below is the block the report quotes.
    Report: https://cdn.cantina.xyz/reports/cantina_level_money_october_2024.pdf
*/

library Math {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x * y / denominator;
    }
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Fills a mint at a fixed output and reverts when that output is below minOut.
contract LevelMinting {
    MockToken public lvl;
    uint256 public constant ATTACK_FILL = 5e17; // 1_000e18 * 5 / 10_000

    constructor(MockToken lvl_) {
        lvl = lvl_;
    }

    function mint(address beneficiary, uint256 minOut) external returns (uint256) {
        require(ATTACK_FILL >= minOut, "minOut");
        lvl.mint(beneficiary, ATTACK_FILL);
        return ATTACK_FILL;
    }
}

contract LevelBaseReserveManager {
    using Math for uint256;

    uint16 public constant MAX_BASIS_POINTS = 1e4;
    uint16 public maxSlippageThresholdBasisPoints = 5;
    LevelMinting public levelMinting;
    uint256 public minOutPassed;

    constructor(LevelMinting levelMinting_) {
        levelMinting = levelMinting_;
    }

    function mintlvlUSD(address collateral, uint256 collateralAmount) external returns (uint256) {
        MockToken(collateral).transferFrom(msg.sender, address(levelMinting), collateralAmount);
        uint256 lvlUSDAmount = collateralAmount;
        // Apply max slippage threshold
        lvlUSDAmount = lvlUSDAmount.mulDiv(
            maxSlippageThresholdBasisPoints,
            MAX_BASIS_POINTS
        );
        minOutPassed = lvlUSDAmount;
        // FIX: lvlUSDAmount -= lvlUSDAmount.mulDiv(maxSlippageThresholdBasisPoints, MAX_BASIS_POINTS);
        // @> VULN: mint is called with the 5 bps slice (0.5) as minOut, not the quote minus that slice (999.5)
        return levelMinting.mint(msg.sender, minOutPassed);
    }
}

contract LevelBaseReserveManagerFixed {
    using Math for uint256;

    uint16 public constant MAX_BASIS_POINTS = 1e4;
    uint16 public maxSlippageThresholdBasisPoints = 5;
    LevelMinting public levelMinting;

    constructor(LevelMinting levelMinting_) {
        levelMinting = levelMinting_;
    }

    function mintlvlUSD(address collateral, uint256 collateralAmount) external returns (uint256) {
        MockToken(collateral).transferFrom(msg.sender, address(levelMinting), collateralAmount);
        uint256 lvlUSDAmount = collateralAmount;
        // Apply max slippage threshold
        lvlUSDAmount -= lvlUSDAmount.mulDiv(
            maxSlippageThresholdBasisPoints,
            MAX_BASIS_POINTS
        );
        return levelMinting.mint(msg.sender, lvlUSDAmount);
    }
}

contract Exploit {
    uint256 public constant COLLATERAL_IN = 1000 ether;
    uint256 public constant STATED_MIN = 999.5 ether;
    uint256 public constant RECEIVED_DUST = 0.5 ether;

    MockToken public collateral;
    MockToken public lvl;
    LevelMinting public minting;
    LevelBaseReserveManager public manager;
    uint256 public received;
    uint256 public statedMin;

    function run() external {
        collateral = new MockToken("USD Coin", "USDC");
        lvl = new MockToken("Level USD", "lvlUSD");
        minting = new LevelMinting(lvl);
        manager = new LevelBaseReserveManager(minting);

        collateral.mint(address(this), COLLATERAL_IN);
        collateral.approve(address(manager), COLLATERAL_IN);
        statedMin = STATED_MIN;
        received = manager.mintlvlUSD(address(collateral), COLLATERAL_IN);

        require(manager.minOutPassed() == RECEIVED_DUST, "floor passed to mint is 0.5");
        require(received == RECEIVED_DUST, "minter received the overwritten floor");
        require(received < statedMin, "not below the stated minimum");
        require(lvl.balanceOf(address(this)) == RECEIVED_DUST, "lvlUSD balance is the dust fill");
        require(collateral.balanceOf(address(this)) == 0, "collateral was taken");
    }
}
