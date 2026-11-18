// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-24 unclosed liquidation (Pashov, 2025-05-06)
    SYNTHETIC, cheatcode-free reduction of LiquidationProxy.closeLiquidation.
    The stored liquidation started at timestamp 0 and the grace length is 0,
    so the deadline is already behind every block.timestamp >= 1. That is the
    state after the report's 72 hour warp. Debt is already 0. The grace check
    still reverts, and withdrawAsset reverts while the flag is set.
    80 ether of collateral stays in the pool. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
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

contract LendingPool {
    struct Position {
        uint256 rawDebtBalance;
        bool isUnderLiquidation;
        bool isInsured;
        uint256 liquidationStartTime;
        uint256 collateral;
    }

    ERC20 public collateralToken;
    uint256 public liquidationGracePeriod;
    mapping(address => Position) public positions;

    constructor(ERC20 c) {
        collateralToken = c;
    }

    function openExpired(address user, uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount); // S1
        positions[user] = Position({
            rawDebtBalance: 0,
            isUnderLiquidation: true,
            isInsured: true,
            liquidationStartTime: 0,
            collateral: amount
        });
    }

    function closeLiquidation() external {
        Position storage position = positions[msg.sender];
        if (block.timestamp > position.liquidationStartTime + liquidationGracePeriod) {
            revert("GracePeriodExpired"); // @> VULN: debt is not read before the grace deadline
        }
        if (!position.isInsured) revert("NotInsured");
        uint256 positionDebt = position.rawDebtBalance;
        if (positionDebt > 0) revert("DebtNotZero");
        position.isUnderLiquidation = false;
    }

    function withdrawAsset() external {
        Position storage position = positions[msg.sender];
        if (position.isUnderLiquidation) revert("CannotWithdrawUnderLiquidation"); // S4
        collateralToken.transfer(msg.sender, position.collateral);
        position.collateral = 0;
    }

    function debtOf(address user) external view returns (uint256) {
        return positions[user].rawDebtBalance;
    }

    function underLiquidation(address user) external view returns (bool) {
        return positions[user].isUnderLiquidation;
    }

    function collateralOf(address user) external view returns (uint256) {
        return positions[user].collateral;
    }
}

contract User {
    function close(LendingPool pool) external {
        pool.closeLiquidation(); // S2
    }

    function withdraw(LendingPool pool) external {
        pool.withdrawAsset(); // S3
    }
}

contract Exploit {
    uint256 public constant FINDING = 66365;
    uint256 public constant LOCKED = 80 ether;
    ERC20 public collateral;
    LendingPool public pool;
    User public user;
    bool public closeReverted;
    bool public withdrawReverted;

    constructor() {
        collateral = new ERC20("crvUSD", 18);
        pool = new LendingPool(collateral);
        user = new User();
    }

    function run() external {
        collateral.mint(address(this), LOCKED);
        collateral.approve(address(pool), LOCKED);
        pool.openExpired(address(user), LOCKED);
        require(pool.debtOf(address(user)) == 0, "debt");
        try user.close(pool) {
            revert("closed");
        } catch {
            closeReverted = true; // S5
        }
        try user.withdraw(pool) {
            revert("withdrew");
        } catch {
            withdrawReverted = true; // S6
        }
        require(closeReverted && withdrawReverted, "reverts");
        require(pool.underLiquidation(address(user)), "flag");
        require(pool.collateralOf(address(user)) == LOCKED, "locked");
        require(collateral.balanceOf(address(pool)) == LOCKED, "pool");
        require(collateral.balanceOf(address(user)) == 0, "user");
    }
}
