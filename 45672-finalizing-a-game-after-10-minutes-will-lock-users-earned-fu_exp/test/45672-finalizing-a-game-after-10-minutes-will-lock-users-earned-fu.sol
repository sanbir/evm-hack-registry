// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro UpDown.finalizeGame — a report that is neither within 10 minutes of
    endTime nor fresh is rejected, so two hours later the pot is refunded to
    both sides (Zokyo, finding 45672).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the OR freshness check reverts for the only report still
    available (30 minutes old, 90 minutes after the end). The game master
    must refund every player, including the side that lost. The true winner
    is paid only their stake, not the pot.
    The blamed require is preserved verbatim (@> VULN). */

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Sink {}

contract UpDown {
    MockERC20 public token;
    uint256 public endTime;
    uint256 public startingPrice;
    address public up;
    address public down;
    bool public immutable exactEnd;
    uint256 public constant STAKE = 100 ether;
    bool public refunded;

    constructor(MockERC20 t, bool exactEnd_) {
        token = t;
        exactEnd = exactEnd_;
        startingPrice = 1000;
    }

    function open(address up_, address down_) external {
        up = up_;
        down = down_;
        endTime = block.timestamp - 2 hours;
        token.transferFrom(msg.sender, address(this), STAKE * 2);
    }

    function priceAt(uint256 ts) public view returns (uint256) {
        if (ts == endTime) return 1100;
        return 900;
    }

    function finalizeGame(uint256 priceTimestamp) external {
        require(block.timestamp >= endTime, "Too early to finish");
        uint256 price = priceAt(priceTimestamp);
        if (!exactEnd) {
            // @> VULN: report is too late for endTime and too old to be fresh, so finalize reverts
            require(
                priceTimestamp - endTime <= 10 minutes || block.timestamp - priceTimestamp <= 10 minutes,
                "Old chainlink report"
            );
        } else {
            require(priceTimestamp == endTime, "not the end report");
        }
        if (price > startingPrice) {
            token.transfer(up, STAKE * 2);
        } else {
            token.transfer(down, STAKE * 2);
        }
    }

    function refund() external {
        token.transfer(up, STAKE);
        token.transfer(down, STAKE);
        refunded = true;
    }
}

contract Exploit {
    MockERC20 public token; // nonce 1
    Sink public upV; // nonce 2
    Sink public downV; // nonce 3
    UpDown public game; // nonce 4
    Sink public upC; // nonce 5
    Sink public downC; // nonce 6
    UpDown public control; // nonce 7

    bool public reverted;
    uint256 public downRefunded;
    uint256 public controlUpPaid;

    constructor() {
        token = new MockERC20();
        upV = new Sink();
        downV = new Sink();
        game = new UpDown(token, false);
        upC = new Sink();
        downC = new Sink();
        control = new UpDown(token, true);
        token.mint(address(this), 400 ether);
    }

    function run() external {
        game.open(address(upV), address(downV));
        uint256 stale = block.timestamp - 30 minutes;
        try game.finalizeGame(stale) {
            revert("late report was accepted");
        } catch {
            reverted = true;
        }
        require(reverted, "finalize did not revert");
        game.refund();
        downRefunded = token.balanceOf(address(downV));
        require(downRefunded == 100 ether, "loser was not refunded the stake");
        require(token.balanceOf(address(upV)) == 100 ether, "winner was paid the pot");
        require(game.refunded(), "not refunded");

        control.open(address(upC), address(downC));
        control.finalizeGame(control.endTime());
        controlUpPaid = token.balanceOf(address(upC));
        require(controlUpPaid == 200 ether, "control did not pay the true winner");
        require(token.balanceOf(address(downC)) == 0, "control refunded the loser");
    }
}
