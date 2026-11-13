// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 60261 — Arkham Intel Exchange BountyV1.closeBounty (Quantstamp).
 * Comments say excess funding from rejected submissions is accrued as fees.
 * closeBounty only does _accruedFees += fee(excessAccrued, true). fee() is the
 * protocol cut (10% here). The other 900 of a 1,000 excess stays in the contract
 * after the funder is repaid their initial amount and the owner withdraws fees.
 */

contract BountyToken {
    string public name = "Bounty token";
    string public symbol = "BNT";
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BountyV1 {
    struct Bounty {
        uint256 amount;
        uint256 initialAmount;
        address funder;
    }

    BountyToken public token;
    address public owner;
    uint256 public _accruedFees;
    mapping(uint256 => Bounty) public _bounties;

    constructor(BountyToken _token, address _owner) {
        token = _token;
        owner = _owner;
    }

    function fee(uint256 amount, bool) public pure returns (uint256) {
        return amount / 10;
    }

    function fund(uint256 bountyId, address funder, uint256 initialAmount, uint256 extra) external {
        uint256 total = initialAmount + extra;
        token.transferFrom(msg.sender, address(this), total);
        _bounties[bountyId] = Bounty(total, initialAmount, funder);
    }

    function closeBounty(uint256 bounty) external {
        uint256 excessAccrued;
        if (_bounties[bounty].amount > _bounties[bounty].initialAmount) {
            excessAccrued = _bounties[bounty].amount - _bounties[bounty].initialAmount;
            // @> VULN:
            _accruedFees += fee(excessAccrued, true);
            _bounties[bounty].amount = _bounties[bounty].initialAmount;
        }
        uint256 refund = _bounties[bounty].amount;
        address funder = _bounties[bounty].funder;
        _bounties[bounty].amount = 0;
        token.transfer(funder, refund);
    }

    function burnAndWithdraw() external {
        require(msg.sender == owner, "owner");
        uint256 f = _accruedFees;
        _accruedFees = 0;
        token.transfer(owner, f);
    }
}

contract BountyV1Fixed {
    struct Bounty {
        uint256 amount;
        uint256 initialAmount;
        address funder;
    }

    BountyToken public token;
    address public owner;
    uint256 public _accruedFees;
    mapping(uint256 => Bounty) public _bounties;

    constructor(BountyToken _token, address _owner) {
        token = _token;
        owner = _owner;
    }

    function fund(uint256 bountyId, address funder, uint256 initialAmount, uint256 extra) external {
        uint256 total = initialAmount + extra;
        token.transferFrom(msg.sender, address(this), total);
        _bounties[bountyId] = Bounty(total, initialAmount, funder);
    }

    function closeBounty(uint256 bounty) external {
        if (_bounties[bounty].amount > _bounties[bounty].initialAmount) {
            uint256 excessAccrued = _bounties[bounty].amount - _bounties[bounty].initialAmount;
            _accruedFees += excessAccrued;
            _bounties[bounty].amount = _bounties[bounty].initialAmount;
        }
        uint256 refund = _bounties[bounty].amount;
        address funder = _bounties[bounty].funder;
        _bounties[bounty].amount = 0;
        token.transfer(funder, refund);
    }

    function burnAndWithdraw() external {
        uint256 f = _accruedFees;
        _accruedFees = 0;
        token.transfer(owner, f);
    }
}

contract Exploit {
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;
    address internal constant OWNER = 0x7777777777777777777777777777777777777777;
    uint256 internal constant INITIAL = 1_000 ether;
    uint256 internal constant EXCESS = 1_000 ether;

    BountyToken public token;
    BountyV1 public bounty;
    uint256 public locked;

    function run() external {
        token = new BountyToken();
        bounty = new BountyV1(token, address(this));
        token.mint(address(this), INITIAL + EXCESS);
        token.approve(address(bounty), INITIAL + EXCESS);
        bounty.fund(1, FUNDER, INITIAL, EXCESS);
        bounty.closeBounty(1);
        bounty.burnAndWithdraw();
        locked = token.balanceOf(address(bounty));
        require(locked == 900 ether, "locked");
        require(token.balanceOf(FUNDER) == INITIAL, "refund");
        require(token.balanceOf(address(this)) == 100 ether, "fee only");
    }
}
