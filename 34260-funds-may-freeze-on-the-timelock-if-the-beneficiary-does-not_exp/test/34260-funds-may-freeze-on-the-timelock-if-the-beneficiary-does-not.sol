// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// dForce DefaultTimeLock.claim requires msg.sender == beneficiary (MixBytes).
/// 100 tokens locked for a contract that cannot call claim stay in the timelock.

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ImmutableSink {}

contract DefaultTimeLock {
    struct Agreement {
        address beneficiary;
        uint256 amount;
        bool open;
    }

    Asset public token;
    Agreement[] public agreements;

    constructor(Asset t) {
        token = t;
    }

    function execute(address beneficiary, uint256 amount) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount);
        id = agreements.length;
        agreements.push(Agreement({beneficiary: beneficiary, amount: amount, open: true}));
    }

    function claim(uint256 id) external {
        Agreement storage a = agreements[id];
        require(a.open, "closed");
        // @> VULN: a beneficiary contract with no way to call claim can never receive the tokens
        require(msg.sender == a.beneficiary, "beneficiary");
        a.open = false;
        token.transfer(a.beneficiary, a.amount);
    }

    function claimFixed(uint256 id) external {
        Agreement storage a = agreements[id];
        require(a.open, "closed");
        a.open = false;
        token.transfer(a.beneficiary, a.amount);
    }
}

contract Exploit {
    Asset public token;
    ImmutableSink public sink;
    DefaultTimeLock public timelock;
    uint256 public lockedId;
    uint256 public frozen;
    bool public claimReverted;

    constructor() {
        token = new Asset();
        sink = new ImmutableSink();
        timelock = new DefaultTimeLock(token);
        token.mint(address(this), 100 ether);
        token.approve(address(timelock), 100 ether);
    }

    function run() external {
        lockedId = timelock.execute(address(sink), 100 ether);
        (bool ok,) = address(timelock).call(abi.encodeWithSelector(timelock.claim.selector, lockedId));
        claimReverted = !ok;
        frozen = token.balanceOf(address(timelock));
        require(lockedId == 0, "id");
        require(claimReverted, "claimed");
        require(frozen == 100 ether, "frozen");
        require(token.balanceOf(address(sink)) == 0, "sink");
    }

    function runControl() external {
        uint256 id = timelock.execute(address(sink), 100 ether);
        timelock.claimFixed(id);
        require(token.balanceOf(address(sink)) == 100 ether, "delivered");
        require(token.balanceOf(address(timelock)) == 0, "empty");
    }
}
