// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Devve Treasury — settleProjectOwnerFunds ignores USDT decimals
    (Zokyo, 2024-06-30 Devve, high).

    SYNTHETIC, cheatcode-free reduction. users.amount is 1000 whole USDT.
    The token has 6 decimals, so the owner is owed 1000 * 10**6 raw units.
    The audited line sets _amountToWithdraw = users.amount and transfers
    that. The owner receives 1000 raw units. The control multiplies by
    10**decimals and pays 1000000000. The other 999999000 stay in the
    treasury. */

struct Whitelist {
    address userAddress;
    uint256 projectId;
    uint256 amount;
    bool inETH;
    uint256 platformFee;
}

contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ProjectOwner {}

contract Treasury {
    MockUSDT public usdt;
    address public owner;
    mapping(uint256 => mapping(bool => uint256)) public fundsWithdrawn;
    mapping(uint256 => uint256) public projectTotalCollectedInUSDT;

    constructor(address _usdt) {
        usdt = MockUSDT(_usdt);
        owner = msg.sender;
    }

    function fundProject(uint256 projectId, uint256 rawCollected) external {
        projectTotalCollectedInUSDT[projectId] = rawCollected;
    }

    function settleProjectOwnerFunds(Whitelist memory users) external virtual {
        require(msg.sender == owner, "!Owner");
        require(!users.inETH, "USDT");
        uint _amountToWithdraw = users.amount ;
        // @> VULN: this posts the unscaled users.amount, not amount times 10**decimals
        fundsWithdrawn[users.projectId][users.inETH] += _amountToWithdraw;
        require(projectTotalCollectedInUSDT[users.projectId] >= _amountToWithdraw, "collected");
        projectTotalCollectedInUSDT[users.projectId] -= _amountToWithdraw;
        require(usdt.transfer(users.userAddress, _amountToWithdraw), "transfer");
    }
}

/// Same body. The withdrawn amount is users.amount times 10**decimals.
contract TreasuryFixed is Treasury {
    constructor(address _usdt) Treasury(_usdt) {}

    function settleProjectOwnerFunds(Whitelist memory users) external override {
        require(msg.sender == owner, "!Owner");
        require(!users.inETH, "USDT");
        // FIX: scale the whole-token amount into raw USDT units
        uint256 scale = 10 ** uint256(usdt.decimals());
        uint256 _amountToWithdraw = users.amount * scale;
        fundsWithdrawn[users.projectId][users.inETH] += _amountToWithdraw;
        require(projectTotalCollectedInUSDT[users.projectId] >= _amountToWithdraw, "collected");
        projectTotalCollectedInUSDT[users.projectId] -= _amountToWithdraw;
        require(usdt.transfer(users.userAddress, _amountToWithdraw), "transfer");
    }
}

contract Exploit {
    uint256 public constant WHOLE = 1000;
    uint256 public constant PAID = 1000;
    uint256 public constant FAIR = 1000000000;
    uint256 public constant SHORTFALL = 999999000;

    MockUSDT public usdt; // CREATE nonce 1
    ProjectOwner public projectOwner; // CREATE nonce 2
    Treasury public treasury; // CREATE nonce 3

    uint256 public paid;
    uint256 public fairPay;
    uint256 public retained;

    constructor() {
        usdt = new MockUSDT();
        projectOwner = new ProjectOwner();
        treasury = new Treasury(address(usdt));
    }

    function run() external {
        uint256 scale = 10 ** uint256(usdt.decimals());
        require(usdt.decimals() == 6, "decimals");
        fairPay = WHOLE * scale;
        require(fairPay == FAIR, "fair scale");
        usdt.mint(address(treasury), fairPay);
        treasury.fundProject(1, fairPay);
        require(usdt.balanceOf(address(treasury)) == FAIR, "seated");
        Whitelist memory users = Whitelist({
            userAddress: address(projectOwner),
            projectId: 1,
            amount: WHOLE,
            inETH: false,
            platformFee: 0
        });
        treasury.settleProjectOwnerFunds(users);
        paid = usdt.balanceOf(address(projectOwner));
        retained = usdt.balanceOf(address(treasury));
        require(paid == PAID, "paid");
        require(paid != fairPay, "not fair");
        require(retained == SHORTFALL, "shortfall");
        require(fairPay - paid == SHORTFALL, "gap");
    }
}
