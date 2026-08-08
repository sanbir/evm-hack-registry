// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    BOB Staking — instantWithdraw does not transfer amountForContract
    (Pashov Audit Group, BOB-Staking 2025-10-18, finding #63717)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: when a staker has a governance delegatee, instantWithdraw
    pulls only amountForUser from the surrogate and never moves
    amountForContract (the early-withdraw penalty) back to BobStaking.
    Penalty tokens stay locked in the surrogate forever while rewardTokenBalance
    is inflated on paper. Vulnerable transfer path preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Surrogate holds delegated stake tokens and approves BobStaking.
contract DelegationSurrogate {
    constructor(address token, address staking) {
        MockERC20(token).approve(staking, type(uint256).max);
    }
}

/// @notice Reduced BobStaking focusing on stake / alterGovernanceDelegatee / instantWithdraw.
/// Source: BobStaking.instantWithdraw (Pashov BOB-Staking 2025-10-18).
contract BobStaking {
    MockERC20 public immutable stakingToken;

    struct Staker {
        uint256 amountStaked;
        address governanceDelegatee;
        uint80 unlockTimestamp;
        uint80 lockPeriod;
    }

    mapping(address => Staker) public stakers;
    mapping(address => DelegationSurrogate) public storedSurrogates;
    mapping(address => bool) public whitelistedDelegatee;

    uint256 public stakingTokenBalance;
    uint256 public rewardTokenBalance;
    uint256 public instantWithdrawalRate = 50; // 50% to user, 50% penalty

    constructor(MockERC20 _token) {
        stakingToken = _token;
    }

    function setWhitelistedDelegatee(address d, bool ok) external {
        whitelistedDelegatee[d] = ok;
    }

    function stake(uint256 amount, address receiver, uint80 /*lockPeriod*/) external {
        require(amount > 0, "zero");
        stakingToken.transferFrom(msg.sender, address(this), amount);
        stakers[receiver].amountStaked += amount;
        stakingTokenBalance += amount;
    }

    function alterGovernanceDelegatee(address newDelegatee) external {
        Staker storage st = stakers[msg.sender];
        require(st.amountStaked > 0, "zero stake");
        require(st.governanceDelegatee != newDelegatee, "unchanged");
        require(newDelegatee == address(0) || whitelistedDelegatee[newDelegatee], "not wl");

        DelegationSurrogate newSurrogate = _fetchOrDeploySurrogate(newDelegatee);

        if (st.governanceDelegatee == address(0)) {
            stakingToken.transfer(address(newSurrogate), st.amountStaked);
        } else {
            DelegationSurrogate oldSurrogate = storedSurrogates[st.governanceDelegatee];
            stakingToken.transferFrom(address(oldSurrogate), address(newSurrogate), st.amountStaked);
        }
        st.governanceDelegatee = newDelegatee;
    }

    function _fetchOrDeploySurrogate(address delegatee) internal returns (DelegationSurrogate s) {
        s = storedSurrogates[delegatee];
        if (address(s) == address(0)) {
            s = new DelegationSurrogate(address(stakingToken), address(this));
            storedSurrogates[delegatee] = s;
        }
    }

    function instantWithdraw(address _receiver) external {
        Staker storage st = stakers[msg.sender];
        // lock / unbond checks omitted for synthetic (unlockTimestamp default 0)

        uint256 amount = st.amountStaked;
        require(amount > 0, "bal");

        stakingTokenBalance -= amount;

        uint256 _amountForUser = (amount * instantWithdrawalRate) / 100;
        uint256 _amountForContract = amount - _amountForUser;

        rewardTokenBalance += _amountForContract;

        if (st.governanceDelegatee != address(0)) {
            // Tokens live in the surrogate
            DelegationSurrogate surrogate = storedSurrogates[st.governanceDelegatee];
            // FIX: also safeTransferFrom(surrogate, address(this), _amountForContract);
            stakingToken.transferFrom(address(surrogate), _receiver, _amountForUser); // @> VULN: only amountForUser pulled; amountForContract stays in surrogate
        } else {
            stakingToken.transfer(_receiver, _amountForUser);
            // penalty already sits in this contract when not delegated
        }

        delete stakers[msg.sender];
    }
}

/// @notice Demonstrates penalty tokens permanently stuck in the surrogate.
/// CREATE order: token (1), staking (2). Surrogate created at run-time.
contract Exploit {
    MockERC20 public token;
    BobStaking public staking;

    uint256 public stuckInSurrogate;
    uint256 public userReceived;
    uint256 public contractBefore;
    uint256 public contractAfter;

    constructor() {
        token = new MockERC20("BOB", "BOB"); // 1
        staking = new BobStaking(token); // 2
    }

    function run() external {
        // Seed rewards in the staking contract (accounting target for penalties)
        token.mint(address(this), 1000e18);
        token.transfer(address(staking), 1000e18);

        // Staker funds
        token.mint(address(this), 1e18);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1e18, address(this), 0);

        address delegatee = address(0xD1);
        staking.setWhitelistedDelegatee(delegatee, true);
        staking.alterGovernanceDelegatee(delegatee);

        DelegationSurrogate surrogate = staking.storedSurrogates(delegatee);
        require(token.balanceOf(address(surrogate)) == 1e18, "in surrogate");

        contractBefore = token.balanceOf(address(staking));

        staking.instantWithdraw(address(this));

        contractAfter = token.balanceOf(address(staking));
        stuckInSurrogate = token.balanceOf(address(surrogate));
        userReceived = token.balanceOf(address(this)); // residual after stake path: mint leftover 0 + half back

        // Harm: penalty half stuck in surrogate; staking balance unchanged (did not receive penalty)
        require(stuckInSurrogate == 0.5e18, "penalty stuck in surrogate");
        require(contractAfter == contractBefore, "contract never received penalty");
        require(staking.rewardTokenBalance() == 0.5e18, "paper reward inflated");
        require(userReceived == 0.5e18, "user got only half");
    }
}
