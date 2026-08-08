// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-03] Interest rates are incorrect on Liquidation
    (Code4rena 2022-11-paraspace; #15976, reporter csanuragjain)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _burnDebtTokens transfers repaid debt to xToken BEFORE
    updateInterestRates(..., liquidityAdded, 0). calculateInterestRates does
    balanceOf(xToken) + liquidityAdded, double-counting the repayment so
    availableLiquidity is too high and currentLiquidityRate is understated.
    Vulnerable transfer-before-rates order preserved verbatim (@>). */

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract XTokenVault {
    // Holds reserve liquidity (stand-in for aToken/xToken address).
}

/// @dev Reduced DefaultReserveInterestRateStrategy.calculateInterestRates.
contract InterestRateStrategy {
    uint256 public constant RAY = 1e27;
    uint256 public constant VARIABLE_BORROW_RATE = 1e26; // 0.1 ray

    struct CalcParams {
        uint256 liquidityAdded;
        uint256 liquidityTaken;
        uint256 totalVariableDebt;
        uint256 reserveFactor; // /10000
        address reserve;
        address xToken;
    }

    function calculateInterestRates(CalcParams memory params)
        public
        view
        returns (uint256 currentLiquidityRate, uint256 currentVariableBorrowRate)
    {
        currentVariableBorrowRate = VARIABLE_BORROW_RATE;
        uint256 totalDebt = params.totalVariableDebt;
        if (totalDebt != 0) {
            // Verbatim shape:
            uint256 availableLiquidity = MockERC20(params.reserve).balanceOf(params.xToken)
                + params.liquidityAdded
                - params.liquidityTaken;

            uint256 availableLiquidityPlusDebt = availableLiquidity + totalDebt;
            uint256 supplyUsageRatio = (totalDebt * RAY) / availableLiquidityPlusDebt;
            currentLiquidityRate =
                (currentVariableBorrowRate * supplyUsageRatio / RAY) * (10000 - params.reserveFactor) / 10000;
        }
    }
}

/// @dev Reduced LiquidationLogic._burnDebtTokens with the transfer-before-rates bug.
contract LiquidationLogic {
    MockERC20 public debtAsset;
    address public xToken;
    InterestRateStrategy public strategy;
    uint256 public totalVariableDebt;
    uint256 public lastLiquidityRate;
    uint256 public constant RESERVE_FACTOR = 1000;

    constructor(MockERC20 _debt, address _xToken, InterestRateStrategy _strategy) {
        debtAsset = _debt;
        xToken = _xToken;
        strategy = _strategy;
    }

    function setDebt(uint256 d) external {
        totalVariableDebt = d;
    }

    function burnDebtTokens(address payer, uint256 actualLiquidationAmount) external {
        totalVariableDebt -= actualLiquidationAmount;

        // Transfers the debt asset being repaid to the xToken, where the liquidity is kept
        debtAsset.transferFrom(payer, xToken, actualLiquidationAmount); // @> VULN: transfer BEFORE rates - xToken bal already includes liquidityAdded
        // FIX: updateInterestRates first, then transferFrom

        // Update borrow & supply rate
        (uint256 liq,) = strategy.calculateInterestRates(
            InterestRateStrategy.CalcParams({
                liquidityAdded: actualLiquidationAmount,
                liquidityTaken: 0,
                totalVariableDebt: totalVariableDebt,
                reserveFactor: RESERVE_FACTOR,
                reserve: address(debtAsset),
                xToken: xToken
            })
        );
        lastLiquidityRate = liq;
    }

    /// @dev Correct order control.
    function burnDebtTokensCorrect(address payer, uint256 actualLiquidationAmount) external {
        totalVariableDebt -= actualLiquidationAmount;
        (uint256 liq,) = strategy.calculateInterestRates(
            InterestRateStrategy.CalcParams({
                liquidityAdded: actualLiquidationAmount,
                liquidityTaken: 0,
                totalVariableDebt: totalVariableDebt,
                reserveFactor: RESERVE_FACTOR,
                reserve: address(debtAsset),
                xToken: xToken
            })
        );
        lastLiquidityRate = liq;
        debtAsset.transferFrom(payer, xToken, actualLiquidationAmount);
    }
}

contract Exploit {
    MockERC20 public debt; // CREATE 1
    XTokenVault public vault; // CREATE 2 - xToken
    InterestRateStrategy public strategy; // CREATE 3
    LiquidationLogic public buggy; // CREATE 4 - vulnerable
    LiquidationLogic public correct; // CREATE 5

    uint256 public constant XTOKEN_BEFORE = 100 ether;
    uint256 public constant DEBT_BEFORE = 100 ether;
    uint256 public constant REPAY = 50 ether;

    uint256 public buggyLiquidityRate;
    uint256 public correctLiquidityRate;

    constructor() {
        debt = new MockERC20();
        vault = new XTokenVault();
        strategy = new InterestRateStrategy();
        buggy = new LiquidationLogic(debt, address(vault), strategy);
        correct = new LiquidationLogic(debt, address(vault), strategy);

        debt.mint(address(vault), XTOKEN_BEFORE);
        debt.mint(address(this), REPAY * 2);
        debt.approve(address(buggy), REPAY);
        debt.approve(address(correct), REPAY);
        buggy.setDebt(DEBT_BEFORE);
        correct.setDebt(DEBT_BEFORE);
    }

    function run() external {
        // Buggy path: transfer then rates → double-count REPAY in availableLiquidity.
        buggy.burnDebtTokens(address(this), REPAY);
        buggyLiquidityRate = buggy.lastLiquidityRate();

        // Reset vault to XTOKEN_BEFORE for the control path.
        // After buggy: vault has BEFORE+REPAY. Move REPAY back to this.
        // Vault has no transfer function - use debt held: we need vault balance = BEFORE.
        // Mint is only path; burn excess by transferring from vault via a helper.
        // Deployed vault is empty of code for transfer - balance stuck.
        // Use a second fresh vault for the control instead (already have correct logic
        // pointing at same vault). Rebuild control against a new vault:

        XTokenVault v2 = new XTokenVault();
        LiquidationLogic good = new LiquidationLogic(debt, address(v2), strategy);
        debt.mint(address(v2), XTOKEN_BEFORE);
        debt.approve(address(good), REPAY);
        good.setDebt(DEBT_BEFORE);
        good.burnDebtTokensCorrect(address(this), REPAY);
        correctLiquidityRate = good.lastLiquidityRate();

        // Buggy availableLiquidity = (100+50)+50 = 200, debt left 50 → util 50/250
        // Correct availableLiquidity = 100+50 = 150, debt left 50 → util 50/200
        // Higher util → higher liquidity rate on correct path.
        require(correctLiquidityRate > buggyLiquidityRate, "buggy understates liquidity rate");
        require(buggyLiquidityRate > 0 && correctLiquidityRate > 0, "rates set");
        // Material distortion: rates differ.
        require(
            correctLiquidityRate - buggyLiquidityRate > 1e20,
            "harm: liquidation double-counts liquidity and warps interest rates"
        );
    }
}
