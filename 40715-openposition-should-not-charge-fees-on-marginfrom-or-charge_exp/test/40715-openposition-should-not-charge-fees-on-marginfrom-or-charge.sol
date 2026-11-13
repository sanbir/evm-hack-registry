// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Particle — openPosition fees the user's own marginFrom
    (Cantina, Feb 2024, finding #40715, cccz).
    SYNTHETIC, cheatcode-free. The fee product is the audited expression (@> VULN).
    ETH:USDC = 3000. A long that posts 6000 USDC as marginFrom is charged on that
    6000 even though nothing was borrowed. Posting the same risk as marginTo
    makes marginFrom zero and the fee disappears. */

library Base {
    uint256 internal constant BASIS_POINT = 10_000;
}

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

struct OpenParams {
    uint256 marginFrom;
    uint256 marginTo;
}

struct Cache {
    uint256 feeFactor;
    uint256 amountFromBorrowed;
    uint256 feeAmount;
}

contract OpenBook {
    FeeToken public immutable token;
    uint256 public feeFactor = 100;
    address public feeRecipient;
    uint256 public feesTaken;
    uint256 public lastFee;
    uint256 public lastMarginTo;

    constructor(FeeToken token_) {
        token = token_;
        feeRecipient = address(this);
    }

    function openPosition(OpenParams calldata params) external returns (uint256 feeAmount) {
        Cache memory cache;
        cache.feeFactor = feeFactor;
        cache.amountFromBorrowed = 0;
        if (cache.feeFactor > 0) {
            // @> VULN: marginFrom is the user's own collateral, but it is added into the fee base.
            cache.feeAmount = ((params.marginFrom + cache.amountFromBorrowed) * cache.feeFactor) / Base.BASIS_POINT;
        }
        // FIX: cache.feeAmount = (cache.amountFromBorrowed * cache.feeFactor) / Base.BASIS_POINT;
        feeAmount = cache.feeAmount;
        lastFee = feeAmount;
        lastMarginTo = params.marginTo;
        if (feeAmount > 0) {
            token.transferFrom(msg.sender, feeRecipient, feeAmount);
            feesTaken += feeAmount;
        }
    }

    function fairFee(uint256 amountFromBorrowed) external view returns (uint256) {
        return (amountFromBorrowed * feeFactor) / Base.BASIS_POINT;
    }
}

contract Exploit {
    FeeToken public token; // nonce 1
    OpenBook public book; // nonce 2

    constructor() {
        token = new FeeToken();
        book = new OpenBook(token);
    }

    function run() external {
        token.mint(address(this), 6000);
        token.approve(address(book), type(uint256).max);
        uint256 charged = book.openPosition(OpenParams({marginFrom: 6000, marginTo: 0}));
        uint256 fair = book.fairFee(0);
        require(charged == 60, "6000 marginFrom is charged 60");
        require(fair == 0, "nothing was borrowed");
        require(token.balanceOf(address(book)) == 60, "protocol took 60");
        uint256 bypass = book.openPosition(OpenParams({marginFrom: 0, marginTo: 2}));
        require(bypass == 0, "marginTo path pays 0");
        require(token.balanceOf(address(book)) == 60, "bypass adds no fee");
    }
}
