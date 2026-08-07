// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// REAL audited source (byte-identical to evk-periphery @ 647866626fbceec6...):
import {HookTargetStakeDelegator, ERC20ShareRepresentation} from "../src/HookTarget/HookTargetStakeDelegator.sol";
// Negative control: same contract with ONLY the MixBytes fix applied.
import {HookTargetStakeDelegatorFixed} from "./FixedHookTargetStakeDelegator.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////////////////
                    FAITHFUL EXTERNAL-BOUNDARY DOUBLES

  Only the opaque, out-of-scope contracts around HookTargetStakeDelegator are
  represented here. The vulnerable contract itself is the REAL audited source.

  - MockRewardVault    : faithful re-implementation of Berachain's POL
                         RewardVault delegate-staking accounting. `delegateStake`
                         PULLS the stake token via transferFrom (exactly as the
                         real `_stake` -> `stakeToken.safeTransferFrom(msg.sender,...)`),
                         `delegateWithdraw` returns it, `getDelegateStake` reads the
                         per-(account,delegate) ledger. This token-backed behaviour
                         is what turns the double-count into a hard failure.
  - MockRewardVaultFactory : deterministic CREATE2 factory so the hook's
                         constructor `predictRewardVaultAddress(erc20)` matches the
                         later `createRewardVault(erc20)`, like the real factory.
  - MockEVault         : the hook's owner/caller; exposes name/symbol/EVC/balanceOf.
  - MockEVC            : account-owner registry; `getAccountOwner` transitions
                         0 -> owner exactly like EVC lazy owner registration.
//////////////////////////////////////////////////////////////////////////*/

interface IHookDrive {
    function deposit(uint256, address receiver) external returns (uint256);
    function checkVaultStatus() external returns (bytes4);
}

contract MockRewardVault {
    address public immutable stakeToken;
    mapping(address account => mapping(address delegate => uint256)) internal _stakedByDelegate;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _stakeToken) {
        stakeToken = _stakeToken;
    }

    // Faithful to Berachain RewardVault.delegateStake + StakingRewards._stake:
    // ledger is credited and the stake token is pulled from the caller (the hook).
    function delegateStake(address account, uint256 amount) external {
        require(account != address(0), "zero");
        require(msg.sender != account, "not delegate");
        _stakedByDelegate[account][msg.sender] += amount;
        balanceOf[account] += amount;
        totalSupply += amount;
        // reverts (ERC20InsufficientBalance) if the caller lacks the tokens
        IERC20(stakeToken).transferFrom(msg.sender, address(this), amount);
    }

    function delegateWithdraw(address account, uint256 amount) external {
        require(msg.sender != account, "not delegate");
        uint256 s = _stakedByDelegate[account][msg.sender];
        require(s >= amount, "insufficient delegate stake");
        _stakedByDelegate[account][msg.sender] = s - amount;
        balanceOf[account] -= amount;
        totalSupply -= amount;
        IERC20(stakeToken).transfer(msg.sender, amount);
    }

    function getDelegateStake(address account, address delegate) external view returns (uint256) {
        return _stakedByDelegate[account][delegate];
    }
}

contract MockRewardVaultFactory {
    bytes32 internal constant SALT = bytes32(uint256(1));

    function predictRewardVaultAddress(address stakingToken) public view returns (address) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(MockRewardVault).creationCode, abi.encode(stakingToken)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), SALT, initHash))))
        );
    }

    function createRewardVault(address stakingToken) external returns (address) {
        return address(new MockRewardVault{salt: SALT}(stakingToken));
    }
}

contract MockEVC {
    mapping(address => address) internal _owner;

    function getAccountOwner(address account) external view returns (address) {
        return _owner[account];
    }

    function setAccountOwner(address account, address owner) external {
        _owner[account] = owner;
    }
}

contract MockEVault {
    address public immutable EVC;
    string public name = "Euler Vault: TEST";
    string public symbol = "eTEST";
    mapping(address => uint256) public balanceOf;

    constructor(address _evc) {
        EVC = _evc;
    }

    function setBalance(address account, uint256 bal) external {
        balanceOf[account] = bal;
    }

    // This contract is the hook's Ownable owner, so it must be the caller.
    function snapshotDeposit(address hook, uint256 amount, address receiver) external {
        IHookDrive(hook).deposit(amount, receiver);
    }

    function runCheck(address hook) external {
        IHookDrive(hook).checkVaultStatus();
    }
}

contract PoC_55523_DoubleCountMigratedStake is Test {
    address internal constant OWNER = address(0xA11CE); // the EVC owner
    address internal constant ACCOUNT = address(0xACC0); // its sub-account

    uint256 internal constant S = 100e18; // stake first delegated directly to ACCOUNT (owner not yet registered)
    uint256 internal constant A = 40e18; //  new shares later deposited (triggers migration)

    // ---------------------------------------------------------------------
    // Vulnerable path: the double-counted migrated stake makes the migration
    // deposit try to stake `A + 2*S` while only `A + S` share tokens exist,
    // reverting the whole operation -> permanent DoS of the affected account.
    // ---------------------------------------------------------------------
    function test_DoubleCountMigratedStake_reverts_migration_deposit() public {
        MockEVC evc = new MockEVC();
        MockEVault eVault = new MockEVault(address(evc));
        MockRewardVaultFactory factory = new MockRewardVaultFactory();

        HookTargetStakeDelegator hook = new HookTargetStakeDelegator(address(eVault), address(factory));
        factory.createRewardVault(address(hook.erc20()));

        MockRewardVault rv = MockRewardVault(address(hook.rewardVault()));
        ERC20ShareRepresentation erc20 = hook.erc20();

        // --- Phase 1: ACCOUNT receives S shares while its EVC owner is unregistered.
        // getAccountOwner(ACCOUNT) == 0, so the stake is delegated directly to ACCOUNT.
        eVault.snapshotDeposit(address(hook), S, ACCOUNT); // pre-hook: initialBalance = 0
        eVault.setBalance(ACCOUNT, S); //                     mint S shares
        eVault.runCheck(address(hook)); //                    delta S -> mint S erc20, delegateStake(ACCOUNT, S)

        assertEq(rv.getDelegateStake(ACCOUNT, address(hook)), S, "phase1: ACCOUNT should hold S");
        assertEq(rv.getDelegateStake(OWNER, address(hook)), 0, "phase1: OWNER holds nothing yet");
        assertEq(erc20.balanceOf(address(hook)), 0, "phase1: hook holds no surplus share tokens");
        assertEq(erc20.totalSupply(), S, "phase1: exactly S share tokens exist");

        // --- Phase 2: the EVC owner registers.
        evc.setAccountOwner(ACCOUNT, OWNER);

        // --- Phase 3: ACCOUNT receives A more shares -> migration path runs.
        eVault.snapshotDeposit(address(hook), A, ACCOUNT); // initialBalance = S
        eVault.setBalance(ACCOUNT, S + A); //                 mint A more shares (total S + A)

        // In checkVaultStatus -> _delegateStake(ACCOUNT, A):
        //   _migrateStake already re-stakes S to OWNER (delegateStake(OWNER, S)),
        //   THEN the buggy outer call runs delegateStake(OWNER, A + S).
        //   The hook now holds only A share tokens but the outer call needs A + S,
        //   so transferFrom reverts short by exactly the migrated amount S.
        // This precise revert (needed = A + S, have = A) is the double-count made mechanical.
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(hook), A, A + S
            )
        );
        eVault.runCheck(address(hook));

        // Harm: the operation cannot complete. State is rolled back; the account is
        // permanently unable to receive further shares once a migration is due.
        assertEq(rv.getDelegateStake(ACCOUNT, address(hook)), S, "post: ACCOUNT stake unchanged (op reverted)");
        assertEq(rv.getDelegateStake(OWNER, address(hook)), 0, "post: OWNER never credited (op reverted)");

        emit log_named_uint("migrated stake S (double-counted)", S);
        emit log_named_uint("new deposit A", A);
        emit log_named_uint("share tokens the buggy hook tried to stake to OWNER (A + S)", A + S);
        emit log_named_uint("share tokens actually available to the hook (A)", A);
        emit log_string("=> migration deposit reverts (ERC20InsufficientBalance): permanent DoS");
    }

    // ---------------------------------------------------------------------
    // Negative control: the SAME scenario with only the MixBytes fix applied
    // (migrate first, then delegate the NEW amount) completes and credits the
    // OWNER exactly A + S — no double count, no revert.
    // ---------------------------------------------------------------------
    function test_Fix_removes_double_count_and_operation_succeeds() public {
        MockEVC evc = new MockEVC();
        MockEVault eVault = new MockEVault(address(evc));
        MockRewardVaultFactory factory = new MockRewardVaultFactory();

        HookTargetStakeDelegatorFixed hook = new HookTargetStakeDelegatorFixed(address(eVault), address(factory));
        factory.createRewardVault(address(hook.erc20()));

        MockRewardVault rv = MockRewardVault(address(hook.rewardVault()));
        ERC20ShareRepresentation erc20 = hook.erc20();

        // Phase 1: S delegated directly to ACCOUNT (owner unregistered).
        eVault.snapshotDeposit(address(hook), S, ACCOUNT);
        eVault.setBalance(ACCOUNT, S);
        eVault.runCheck(address(hook));
        assertEq(rv.getDelegateStake(ACCOUNT, address(hook)), S, "fix phase1: ACCOUNT holds S");

        // Phase 2: owner registers.
        evc.setAccountOwner(ACCOUNT, OWNER);

        // Phase 3: ACCOUNT receives A more shares -> migration + new delegation.
        eVault.snapshotDeposit(address(hook), A, ACCOUNT);
        eVault.setBalance(ACCOUNT, S + A);
        eVault.runCheck(address(hook)); // succeeds with the fix

        // Correct accounting: OWNER credited exactly the migrated S plus the new A.
        assertEq(rv.getDelegateStake(OWNER, address(hook)), A + S, "fix: OWNER credited exactly A + S");
        assertEq(rv.getDelegateStake(ACCOUNT, address(hook)), 0, "fix: ACCOUNT stake fully migrated away");
        assertEq(rv.totalSupply(), A + S, "fix: total delegated == total shares (S + A)");
        assertEq(erc20.totalSupply(), A + S, "fix: exactly S + A share tokens minted");
        assertEq(erc20.balanceOf(address(hook)), 0, "fix: no leftover share tokens");
    }
}
