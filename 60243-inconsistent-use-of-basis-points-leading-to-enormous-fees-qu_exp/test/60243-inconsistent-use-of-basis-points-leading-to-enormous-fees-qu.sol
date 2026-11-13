// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 60243 — Altr Lending.sol (Quantstamp).
 * PRECISION is 10000 and MAX_REPAY_GRACE_FEE is 4 * PRECISION (the documented 4% cap).
 * repay does platformFee += (totalPayable * repayGraceFee) / PRECISION, so a 1,000
 * debt at that cap is charged 4,000 — four times the debt — instead of 40.
 */

contract Asset {
    string public name = "Altr asset";
    string public symbol = "ALT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Lending {
    uint256 public constant PRECISION = 10000;
    uint256 public constant MAX_REPAY_GRACE_FEE = 4 * PRECISION;

    Asset public token;
    address public feeTo;
    address public lender;
    uint256 public repayGraceFee;
    uint256 public feeCharged;

    constructor(Asset _token, address _feeTo, address _lender) {
        token = _token;
        feeTo = _feeTo;
        lender = _lender;
        repayGraceFee = MAX_REPAY_GRACE_FEE;
    }

    function repay(uint256 totalPayable) external {
        uint256 platformFee;
        // @> VULN:
        platformFee += (totalPayable * repayGraceFee) / PRECISION;
        feeCharged = platformFee;
        token.transferFrom(msg.sender, feeTo, platformFee);
        token.transferFrom(msg.sender, lender, totalPayable);
    }
}

contract LendingFixed {
    uint256 public constant PRECISION = 10000;
    Asset public token;
    address public feeTo;
    address public lender;
    uint256 public repayGraceFee;
    uint256 public feeCharged;

    constructor(Asset _token, address _feeTo, address _lender) {
        token = _token;
        feeTo = _feeTo;
        lender = _lender;
        repayGraceFee = 400;
    }

    function repay(uint256 totalPayable) external {
        uint256 platformFee = (totalPayable * repayGraceFee) / PRECISION;
        feeCharged = platformFee;
        token.transferFrom(msg.sender, feeTo, platformFee);
        token.transferFrom(msg.sender, lender, totalPayable);
    }
}

contract Exploit {
    address internal constant FEE_TO = 0x3333333333333333333333333333333333333333;
    address internal constant LENDER = 0x5555555555555555555555555555555555555555;
    uint256 internal constant DEBT = 1_000 ether;

    Asset public token;
    Lending public lending;
    uint256 public charged;

    function run() external {
        token = new Asset();
        lending = new Lending(token, FEE_TO, LENDER);
        token.mint(address(this), DEBT + 4_000 ether);
        token.approve(address(lending), type(uint256).max);
        lending.repay(DEBT);
        charged = token.balanceOf(FEE_TO);
        require(charged == 4_000 ether, "fee");
        require(lending.feeCharged() == 4_000 ether, "stored");
        require(token.balanceOf(LENDER) == DEBT, "principal");
    }
}
