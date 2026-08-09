// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of BOB Staking finding 63718
// (Pashov Audit Group, C-02):
// "Stakes not forwarded post-delegation, positions unwithdrawable".
//
// In `BobStaking`, once a user delegates governance via `alterGovernanceDelegatee`,
// their existing stake is moved to a per-delegatee `DelegationSurrogate`. However,
// a LATER `stake()` keeps the new tokens in the staking contract and only bumps
// `amountStaked` — it never forwards the new amount to the surrogate. The exit
// paths `unbond()` / `instantWithdraw()` then assume the FULL `amountStaked` sits
// in the surrogate and `safeTransferFrom(surrogate, ..., amountStaked)`. Because
// the surrogate holds only the pre-delegation portion (and never received the new
// part), that pull reverts — the user can neither unbond nor instant-withdraw and
// the whole position is permanently frozen.
//
// The two verbatim vulnerable lines from the finding are inlined unchanged and
// carry a `// @>` marker on the accounting line that fails to forward.
// The vulnerable target is BobStaking (reconstructed around the verbatim quoted
// lines — source is embedded-solidity, only partial snippets exist upstream).
// Minimal faithful doubles: a MockERC20 staking token and a DelegationSurrogate
// (the real Uniswap flexible-voting surrogate pattern: approve the deployer max
// and delegate voting power; here it holds only the pre-delegation balance).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal faithful SafeERC20: the underlying token reverts on failure, so
///      these wrappers reproduce the real `safeTransfer{,From}` revert behaviour.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

/// @dev Minimal ERC20 double for the opaque staking token. Reverts (not returns
///      false) on insufficient balance/allowance, exactly like a real token under
///      SafeERC20, so the surrogate's balance shortfall surfaces as a revert.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: transfer amount exceeds balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: insufficient allowance");
        require(balanceOf[from] >= amount, "ERC20: transfer amount exceeds balance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Faithful minimal double for the per-delegatee DelegationSurrogate.
///      Real pattern (Uniswap flexible-voting): delegate voting power to the
///      delegatee and approve the deploying staking contract for max, so the
///      staking contract can pull the tokens back on exit. It only ever holds the
///      tokens actually transferred INTO it — the post-delegation re-stake never
///      arrives here, which is the whole bug.
contract DelegationSurrogate {
    constructor(address _delegatee) {
        _delegatee; // real surrogate would call token.delegate(_delegatee) (voting power) — omitted (opaque, out of scope)
    }

    /// @notice Called by the staking contract right after construction to grant
    ///         it pull-back allowance (max), mirroring the real surrogate.
    function approveStaking(IERC20 token) external {
        token.approve(msg.sender, type(uint256).max);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The two verbatim quoted lines are inlined unchanged; the
// `// @>` marker is on the accounting line that fails to forward the new stake.
// ─────────────────────────────────────────────────────────────────────────────
contract BobStaking {
    using SafeERC20 for IERC20;

    struct Staker {
        uint256 amountStaked;
        address governanceDelegatee;
    }

    address internal _stakingToken;
    mapping(address => Staker) public stakers;
    mapping(address => DelegationSurrogate) public storedSurrogates;

    constructor(address stakingToken_) {
        _stakingToken = stakingToken_;
    }

    function _stakeMsgSender() internal view returns (address) {
        return msg.sender;
    }

    function amountStakedOf(address who) external view returns (uint256) {
        return stakers[who].amountStaked;
    }

    /// @notice Stake tokens for `receiver`. VULNERABILITY: when the receiver has
    ///         already delegated (governanceDelegatee != 0) the new tokens are
    ///         kept in THIS contract and never forwarded to the surrogate.
    function stake(uint256 _amount, address receiver, uint256 lockPeriod) external {
        lockPeriod; // unused in this minimal repro
        IERC20(_stakingToken).safeTransferFrom(_stakeMsgSender(), address(this), _amount);
        stakers[receiver].amountStaked += _amount; // @> new stake credited but NOT forwarded to the surrogate when governanceDelegatee != 0 -> custody diverges from accounting
    }

    /// @notice Delegate governance: move the caller's CURRENT stake into a
    ///         per-delegatee surrogate and record the delegatee.
    function alterGovernanceDelegatee(address _delegatee) external {
        address staker = msg.sender;

        DelegationSurrogate surrogate = storedSurrogates[_delegatee];
        if (address(surrogate) == address(0)) {
            surrogate = new DelegationSurrogate(_delegatee);
            surrogate.approveStaking(IERC20(_stakingToken)); // surrogate approves this contract max (pull-back)
            storedSurrogates[_delegatee] = surrogate;
        }

        uint256 current = stakers[staker].amountStaked;
        IERC20(_stakingToken).safeTransfer(address(surrogate), current); // move existing stake to the surrogate
        stakers[staker].governanceDelegatee = _delegatee;
    }

    /// @notice Begin unbonding: pulls the FULL amountStaked back from the surrogate.
    function unbond() external {
        address staker = msg.sender;
        DelegationSurrogate surrogate = storedSurrogates[stakers[staker].governanceDelegatee];
        // verbatim exit assumption: safeTransferFrom(surrogate, this, amountStaked)
        IERC20(_stakingToken).safeTransferFrom(address(surrogate), address(this), stakers[staker].amountStaked);
        stakers[staker].amountStaked = 0;
    }

    /// @notice Instant withdraw: pulls the FULL amount for the user from the surrogate.
    function instantWithdraw(address _receiver) external {
        address staker = msg.sender;
        DelegationSurrogate surrogate = storedSurrogates[stakers[staker].governanceDelegatee];
        uint256 _amountForUser = stakers[staker].amountStaked;
        // verbatim exit assumption: safeTransferFrom(surrogate, _receiver, _amountForUser)
        IERC20(_stakingToken).safeTransferFrom(address(surrogate), _receiver, _amountForUser);
        stakers[staker].amountStaked = 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): stake() forwards the new amount to the
// user's surrogate whenever they are already delegated, keeping a single custody
// location so unbond()/instantWithdraw() find the full balance in the surrogate.
// ─────────────────────────────────────────────────────────────────────────────
contract BobStakingFixed {
    using SafeERC20 for IERC20;

    struct Staker {
        uint256 amountStaked;
        address governanceDelegatee;
    }

    address internal _stakingToken;
    mapping(address => Staker) public stakers;
    mapping(address => DelegationSurrogate) public storedSurrogates;

    constructor(address stakingToken_) {
        _stakingToken = stakingToken_;
    }

    function _stakeMsgSender() internal view returns (address) {
        return msg.sender;
    }

    function amountStakedOf(address who) external view returns (uint256) {
        return stakers[who].amountStaked;
    }

    function stake(uint256 _amount, address receiver, uint256 lockPeriod) external {
        lockPeriod;
        IERC20(_stakingToken).safeTransferFrom(_stakeMsgSender(), address(this), _amount);
        stakers[receiver].amountStaked += _amount;
        // FIX: enforce a single custody location while delegated.
        if (stakers[receiver].governanceDelegatee != address(0)) {
            DelegationSurrogate s = storedSurrogates[stakers[receiver].governanceDelegatee];
            IERC20(_stakingToken).safeTransfer(address(s), _amount);
        }
    }

    function alterGovernanceDelegatee(address _delegatee) external {
        address staker = msg.sender;

        DelegationSurrogate surrogate = storedSurrogates[_delegatee];
        if (address(surrogate) == address(0)) {
            surrogate = new DelegationSurrogate(_delegatee);
            surrogate.approveStaking(IERC20(_stakingToken));
            storedSurrogates[_delegatee] = surrogate;
        }

        uint256 current = stakers[staker].amountStaked;
        IERC20(_stakingToken).safeTransfer(address(surrogate), current);
        stakers[staker].governanceDelegatee = _delegatee;
    }

    function unbond() external returns (uint256) {
        address staker = msg.sender;
        DelegationSurrogate surrogate = storedSurrogates[stakers[staker].governanceDelegatee];
        uint256 amount = stakers[staker].amountStaked;
        IERC20(_stakingToken).safeTransferFrom(address(surrogate), address(this), amount);
        stakers[staker].amountStaked = 0;
        return amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: victim stakes 100, delegates (100 -> surrogate), re-stakes 50
// (kept in staking; amountStaked = 150), then unbond()/instantWithdraw() both
// revert because the surrogate holds only 100 < 150. The 150 staked tokens are
// permanently frozen (50 in BobStaking + 100 in the surrogate). Harm is recorded
// on a LOCKED-STAKE marker token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant DELEGATEE = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant STAKE1 = 100 ether;
    uint256 internal constant STAKE2 = 50 ether;

    // Exposed results for the driver / Playground.
    address public stakingAddr;
    address public markerAddr;
    address public tokenAddr;
    address public surrogateAddr;

    uint256 public amountStakedRecorded; // 150e18
    uint256 public surrogateHeld;        // 100e18
    uint256 public stakingContractHeld;  // 50e18
    uint256 public frozenAmount;         // 150e18
    uint256 public sinkMarkerBalance;    // 150e18
    bool public unbondReverted;
    bool public instantWithdrawReverted;

    function run() external payable {
        // --- deploy the real vulnerable contract + minimal doubles ---
        MockERC20 token = new MockERC20("BOB Stake", "BOB");
        BobStaking staking = new BobStaking(address(token));
        MockERC20 marker = new MockERC20("Locked Stake", "LOCKED-STAKE");

        stakingAddr = address(staking);
        markerAddr = address(marker);
        tokenAddr = address(token);

        // victim == this Exploit contract
        token.mint(address(this), STAKE1 + STAKE2);
        token.approve(address(staking), type(uint256).max);

        // 1. stake 100
        staking.stake(STAKE1, address(this), 0);
        // 2. delegate governance -> existing 100 moved to the surrogate
        staking.alterGovernanceDelegatee(DELEGATEE);
        // 3. re-stake 50 -> stays in the staking contract; amountStaked = 150
        staking.stake(STAKE2, address(this), 0);

        // record the custody split that the exit paths get wrong
        surrogateAddr = address(staking.storedSurrogates(DELEGATEE));
        surrogateHeld = token.balanceOf(surrogateAddr);              // 100e18
        stakingContractHeld = token.balanceOf(address(staking));     // 50e18
        amountStakedRecorded = staking.amountStakedOf(address(this)); // 150e18

        // 4. unbond() reverts: pulls amountStaked (150) from a surrogate holding 100
        try staking.unbond() {
            unbondReverted = false;
        } catch {
            unbondReverted = true;
        }
        // 5. instantWithdraw() reverts for the same reason
        try staking.instantWithdraw(address(this)) {
            instantWithdrawReverted = false;
        } catch {
            instantWithdrawReverted = true;
        }

        require(unbondReverted, "unbond must revert (position frozen)");
        require(instantWithdrawReverted, "instantWithdraw must revert (position frozen)");

        // harm: the entire 150-token position is frozen and unwithdrawable
        frozenAmount = surrogateHeld + stakingContractHeld; // 150e18
        require(frozenAmount == 150 ether, "frozen position must be 150");
        require(amountStakedRecorded == 150 ether, "accounting must show 150 staked");

        // record the harm magnitude on the marker token at the SINK
        marker.mint(SINK, frozenAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
