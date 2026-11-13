// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Curio earlyEndGame subtracts the game fee from the player and never pays the treasury (Pashov H-01).
/// Pot is 1 ETH, take rate is 10%. 0.1 ETH stays in the game. Treasury receives 0.

contract Treasury {
    receive() external payable {}
}

contract Game {
    address public admin;
    address public treasury;
    address public player;
    uint256 public takeRate;
    uint256 public feeTaken;
    uint256 public paidToPlayer;

    struct PlayerPayout {
        uint256 payout;
    }

    constructor(address _treasury, address _player) {
        admin = msg.sender;
        treasury = _treasury;
        player = _player;
        takeRate = 10;
    }

    function fund() external payable {}

    function earlyEndGame(string calldata gameId, PlayerPayout memory playerPayout) external {
        require(msg.sender == admin, "admin");
        gameId;
        uint256 gameFee = (playerPayout.payout * takeRate) / 100;
        playerPayout.payout -= gameFee; // @> VULN: gameFee is taken from the player and left in this contract
        feeTaken = gameFee;
        paidToPlayer = playerPayout.payout;
        (bool sent,) = player.call{value: playerPayout.payout}("");
        require(sent, "player");
    }

    function earlyEndGameFixed(PlayerPayout memory playerPayout) external {
        require(msg.sender == admin, "admin");
        uint256 gameFee = (playerPayout.payout * takeRate) / 100;
        playerPayout.payout -= gameFee;
        feeTaken = gameFee;
        (bool sent,) = player.call{value: playerPayout.payout}("");
        require(sent, "player");
        (bool tsent,) = treasury.call{value: gameFee}("");
        require(tsent, "treasury");
    }
}

contract Exploit {
    Treasury public treasury;
    Game public game;
    address public player;
    uint256 public stuck;
    uint256 public treasuryBal;

    constructor() {
        treasury = new Treasury();
        player = address(new Treasury());
        game = new Game(address(treasury), player);
    }

    function run() external payable {
        uint256 pot = msg.value;
        game.fund{value: pot}();
        game.earlyEndGame("match-1", Game.PlayerPayout({payout: pot}));
        stuck = address(game).balance;
        treasuryBal = address(treasury).balance;
        require(game.feeTaken() == 0.1 ether, "fee");
        require(game.paidToPlayer() == 0.9 ether, "paid");
        require(player.balance == 0.9 ether, "player");
        require(stuck == 0.1 ether, "stuck");
        require(treasuryBal == 0, "treasury");
    }

    function runControl() external payable {
        uint256 pot = msg.value;
        game.fund{value: pot}();
        game.earlyEndGameFixed(Game.PlayerPayout({payout: pot}));
        require(address(game).balance == 0, "not stuck");
        require(address(treasury).balance == 0.1 ether, "treasury paid");
    }
}
