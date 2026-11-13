// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LooksRare Infiltration — claimGrandPrize reads agents[1].agentId
    (Sherlock 2023-10). Rank 1 is written only when two agents are swapped.
    If the winner was never swapped, agentId stays 0, ownership reverts, and
    the grand prize stays in the contract. Seating the winner with id 1 lets
    the same claim pay the prize out. */

contract Cash27587 {
    string public name = "Prize";
    string public symbol = "PRIZE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Infiltration27587 {
    struct Agent {
        uint256 agentId;
        address owner;
    }

    Cash27587 public prize;
    mapping(uint256 => Agent) public agents;
    mapping(uint256 => address) public ownerOf;

    constructor(Cash27587 p) {
        prize = p;
    }

    function seatWinner(address owner, bool initId) external {
        agents[1].owner = owner;
        if (initId) {
            agents[1].agentId = 1;
            ownerOf[1] = owner;
        }
    }

    function claimGrandPrize(address caller) external returns (uint256 paid) {
        uint256 agentId = agents[1].agentId;
        // @> VULN: rank 1 was never swapped, so agentId is still 0. There is no owner for id 0 and the prize claim reverts.
        require(agentId != 0 && ownerOf[agentId] == caller, "not winner");
        paid = prize.balanceOf(address(this));
        prize.transfer(caller, paid);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Cash27587 public prize;
    Infiltration27587 public game;
    Cash27587 public prizeC;
    Infiltration27587 public gameC;

    uint256 public parked;
    uint256 public winnerId;
    bool public claimReverted;
    uint256 public stuck;
    uint256 public winnerGot;
    uint256 public controlId;
    uint256 public controlPaid;
    uint256 public controlLeft;

    function run() external {
        prize = new Cash27587();
        game = new Infiltration27587(prize);
        prizeC = new Cash27587();
        gameC = new Infiltration27587(prizeC);

        prize.mint(address(game), N);
        parked = prize.balanceOf(address(game));
        game.seatWinner(address(this), false);
        winnerId = _agentId(game);

        try game.claimGrandPrize(address(this)) returns (uint256 paid) {
            claimReverted = false;
            winnerGot = paid;
        } catch {
            claimReverted = true;
            winnerGot = 0;
        }
        stuck = prize.balanceOf(address(game));

        prizeC.mint(address(gameC), N);
        gameC.seatWinner(address(this), true);
        controlId = _agentId(gameC);
        controlPaid = gameC.claimGrandPrize(address(this));
        controlLeft = prizeC.balanceOf(address(gameC));

        require(parked == N, "parked");
        require(winnerId == 0, "id");
        require(claimReverted, "claim");
        require(stuck == N, "stuck");
        require(winnerGot == 0, "winner");
        require(prize.balanceOf(address(this)) == 0, "attacker prize");
        require(controlId == 1, "control id");
        require(controlPaid == N, "control paid");
        require(controlLeft == 0, "control left");
        require(prizeC.balanceOf(address(this)) == N, "control got");
    }

    function _agentId(Infiltration27587 g) internal view returns (uint256 id) {
        (id,) = g.agents(1);
    }
}
