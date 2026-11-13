// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — Pashov, 2024-11-16. _acquireBorrowTokenForRepayment.
    A self-lending deleverage swaps pod tokens for lending-pair shares, then
    redeems _podAmtRemaining (pods not spent) instead of the shares received.
    990 pods become 990 shares and only 10 shares are redeemed, so 980 borrow
    tokens never come back and the debt stays open. Redeeming the share
    balance clears the debt.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LendingPair {
    Token public borrowToken;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Token _borrow) {
        borrowToken = _borrow;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function redeem(uint256 shares, address, address) external returns (uint256) {
        require(balanceOf[msg.sender] >= shares, "shares");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(borrowToken.transfer(msg.sender, shares), "borrow");
        return shares;
    }
}

contract Dex {
    LendingPair public pair;

    constructor(LendingPair _pair) {
        pair = _pair;
    }

    function swapV2SingleExactOut(address pod, address, uint256, uint256 targetNeeded, address to) external {
        require(Token(pod).transferFrom(msg.sender, address(this), targetNeeded), "pods");
        pair.mint(to, targetNeeded);
    }
}

contract LeverageManager {
    Token public pod;
    Token public borrowToken;
    LendingPair public pair;
    Dex public dex;
    uint256 public debt;

    constructor(Token _pod, Token _borrow, LendingPair _pair, Dex _dex) {
        pod = _pod;
        borrowToken = _borrow;
        pair = _pair;
        dex = _dex;
    }

    function setDebt(uint256 amount) external {
        debt = amount;
    }

    function _swapPodForBorrowToken(address _pod, address _targetToken, uint256 _podAmt, uint256 _targetNeededAmt)
        internal
        returns (uint256 _podRemainingAmt)
    {
        uint256 _balBefore = Token(_pod).balanceOf(address(this));
        Token(_pod).approve(address(dex), _podAmt);
        dex.swapV2SingleExactOut(_pod, _targetToken, _podAmt, _targetNeededAmt, address(this));
        _podRemainingAmt = _podAmt - (_balBefore - Token(_pod).balanceOf(address(this)));
    }

    function _acquireBorrowTokenForRepayment(uint256 _repayAmount, uint256 _podAmtReceived)
        internal
        returns (uint256 _podAmtRemaining)
    {
        _podAmtRemaining = _podAmtReceived;
        uint256 _borrowAmtNeededToSwap = _repayAmount;
        if (_borrowAmtNeededToSwap > 0) {
            _podAmtRemaining =
                _swapPodForBorrowToken(address(pod), address(pair), _podAmtReceived, _borrowAmtNeededToSwap);
            // @> VULN: redeem is given the leftover pod amount, not the lending-pair shares the swap just minted
            _podAmtRemaining = pair.redeem(_podAmtRemaining, address(this), address(this));
        }
    }

    function removeLeverage(uint256 podAmt, uint256 repayAmount) external {
        require(pod.transferFrom(msg.sender, address(this), podAmt), "pods");
        debt = repayAmount;
        _acquireBorrowTokenForRepayment(repayAmount, podAmt);
        uint256 got = borrowToken.balanceOf(address(this));
        if (got >= debt) {
            debt = 0;
            require(borrowToken.transfer(msg.sender, got), "repay");
        }
    }
}

contract LeverageManagerFixed {
    Token public pod;
    Token public borrowToken;
    LendingPair public pair;
    Dex public dex;

    constructor(Token _pod, Token _borrow, LendingPair _pair, Dex _dex) {
        pod = _pod;
        borrowToken = _borrow;
        pair = _pair;
        dex = _dex;
    }

    function removeLeverage(uint256 podAmt, uint256 repayAmount) external returns (uint256 debtLeft) {
        require(pod.transferFrom(msg.sender, address(this), podAmt), "pods");
        pod.approve(address(dex), podAmt);
        dex.swapV2SingleExactOut(address(pod), address(pair), podAmt, repayAmount, address(this));
        uint256 shares = pair.balanceOf(address(this));
        pair.redeem(shares, address(this), address(this));
        require(borrowToken.transfer(msg.sender, borrowToken.balanceOf(address(this))), "repay");
        return 0;
    }
}

contract Exploit {
    uint256 public constant PODS = 1000 ether;
    uint256 public constant NEED = 990 ether;

    Token public pod;
    Token public borrowToken;
    LendingPair public pair;
    Dex public dex;
    LeverageManager public mgr;
    uint256 public stuckShares;
    uint256 public borrowGot;
    uint256 public debtLeft;

    constructor() {
        pod = new Token("POD");
        borrowToken = new Token("BORROW");
        pair = new LendingPair(borrowToken);
        dex = new Dex(pair);
        mgr = new LeverageManager(pod, borrowToken, pair, dex);
        borrowToken.mint(address(pair), 1000 ether);
        pod.mint(address(this), PODS);
    }

    function run() external {
        pod.approve(address(mgr), PODS);
        mgr.removeLeverage(PODS, NEED);
        stuckShares = pair.balanceOf(address(mgr));
        borrowGot = borrowToken.balanceOf(address(mgr));
        debtLeft = mgr.debt();
        require(stuckShares == 980 ether, "stuck");
        require(borrowGot == 10 ether, "got");
        require(debtLeft == NEED, "debt");
        require(borrowToken.balanceOf(address(this)) == 0, "user");
        require(pair.borrowToken().balanceOf(address(pair)) == 990 ether, "pair");
    }
}
