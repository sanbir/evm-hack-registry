// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol — GiantLP with a `transferHookProcessor` can't be
    burned, users' funds get stuck in the Giant Pool
    (Code4rena 2022-11-stakehouse, #43030, H-07)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `GiantMevAndFeesPool.beforeTokenTransfer` body is inlined
    VERBATIM — including the missing `_to != address(0)` guard that the `_from`
    branch has. The Exploit deploys everything, a user deposits ETH, then shows
    that ANY burn of their GiantLP (i.e. any `withdrawETH`) permanently reverts
    because the transfer hook chokes on the zero-address recipient of a burn
    (no fork, no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `GiantLP._beforeTokenTransfer` invokes
    `transferHookProcessor.beforeTokenTransfer(_from, _to, _amount)`
    unconditionally, including on burn (`_to == address(0)`). The pool's
    `beforeTokenTransfer` implementation guards the `_from` branch with
    `if (_from != address(0))` but has NO equivalent guard for `_to`, so it
    unconditionally calls `_distributeETHRewardsToUserForToken(_to, ...,
    _to)` with `_recipient == address(0)`. That function's FIRST line is
    `require(_recipient != address(0), "Zero address")` — so every burn of
    GiantLP (which is exactly what `withdrawETH` does) reverts.

    Recommended fix (per report): guard the `_to` branch the same way `_from`
    is guarded — `if (_to != address(0)) { _distributeETHRewardsToUserForToken(...); }`.
//////////////////////////////////////////////////////////////*/

/// @dev Reduced abstract reward-accounting base — faithful reduction of
///      contracts/liquid-staking/SyndicateRewardsProcessor.sol. Only the
///      zero-address-checking function matters for this bug; the accrual
///      math is kept so the pool behaves realistically.
abstract contract SyndicateRewardsProcessor {
    uint256 public constant PRECISION = 1e24;
    uint256 public accumulatedETHPerLPShare;
    uint256 public totalClaimed;
    uint256 public totalETHSeen;
    mapping(address => mapping(address => uint256)) public claimed;

    /// @dev VERBATIM reduction of
    ///      SyndicateRewardsProcessor._distributeETHRewardsToUserForToken —
    ///      the unconditional zero-address check is the trigger for this bug.
    function _distributeETHRewardsToUserForToken(
        address _user,
        address _token,
        uint256 _balance,
        address _recipient
    ) internal {
        require(_recipient != address(0), "Zero address"); // @> VULN (trigger): fires unconditionally, even for a burn's _to==0
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

/// @dev Minimal transfer-hook interface, mirrors
///      contracts/interfaces/ITransferHookProcessor.sol.
interface ITransferHookProcessor {
    function beforeTokenTransfer(address from, address to, uint256 amount) external;
    function afterTokenTransfer(address from, address to, uint256 amount) external;
}

/// @notice Reduced `GiantLP` — minimal ERC20-like receipt token with a
///         transfer hook processor, faithful reduction of
///         contracts/liquid-staking/GiantLP.sol (mint/burn restricted to
///         `pool`, `_beforeTokenTransfer` calls the hook unconditionally).
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

    /// @dev Real ERC20._burn calls `_beforeTokenTransfer(account, address(0),
    ///      amount)` — the `to` argument is address(0). Preserved verbatim.
    function burn(address _recipient, uint256 _amount) external {
        require(msg.sender == pool, "Only pool");
        _beforeTokenTransfer(_recipient, address(0), _amount); // @> the `to` arg IS address(0) here — real ERC20._burn semantics
        balanceOf[_recipient] -= _amount;
        totalSupply -= _amount;
    }

    /// @dev VERBATIM reduction of GiantLP._beforeTokenTransfer
    ///      (contracts/liquid-staking/GiantLP.sol#L39-L47) — calls the hook
    ///      unconditionally whenever one is set, with no zero-address guard
    ///      of its own (the guard, if any, must live in the hook processor).
    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal {
        if (address(transferHookProcessor) != address(0)) {
            ITransferHookProcessor(transferHookProcessor).beforeTokenTransfer(_from, _to, _amount);
        }
    }
}

/// @notice Reduced Giant Pool — faithful reduction of `GiantPoolBase` +
///         `GiantMevAndFeesPool` (contracts/liquid-staking/). Keeps
///         `depositETH`, `withdrawETH`, and the buggy `beforeTokenTransfer`
///         verbatim (missing `_to != address(0)` guard).
contract GiantMevAndFeesPool is SyndicateRewardsProcessor, ITransferHookProcessor {
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;
    uint256 public idleETH;
    GiantLP public lpTokenETH;

    constructor() {
        lpTokenETH = new GiantLP(address(this), address(this));
    }

    // ============================================================
    //  GiantPoolBase.depositETH — verbatim reduction
    // ============================================================
    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        idleETH += msg.value;
        lpTokenETH.mint(msg.sender, msg.value);
        _setClaimedToMax(msg.sender);
    }

    // ============================================================
    //  GiantPoolBase.withdrawETH — verbatim reduction. `lpTokenETH.burn`
    //  triggers `beforeTokenTransfer` below, which is where the bug lives.
    // ============================================================
    function withdrawETH(uint256 _amount) external {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(lpTokenETH.balanceOf(msg.sender) >= _amount, "Invalid balance");
        require(idleETH >= _amount, "Come back later or withdraw less ETH");

        idleETH -= _amount;
        lpTokenETH.burn(msg.sender, _amount); // @> triggers beforeTokenTransfer(_from=sender, _to=address(0), amount)
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Failed to transfer ETH");
    }

    // ============================================================
    //  GiantMevAndFeesPool.beforeTokenTransfer — VERBATIM
    //  (contracts/liquid-staking/GiantMevAndFeesPool.sol#L73-L78/L161-L166).
    //  The `_from` branch IS guarded; the `_to` branch is NOT.
    // ============================================================
    function beforeTokenTransfer(address _from, address _to, uint256) external {
        require(msg.sender == address(lpTokenETH), "Caller is not giant LP");
        updateAccumulatedETHPerLP();

        // Make sure that `_from` gets total accrued before transfer as post transferred anything owed will be wiped
        if (_from != address(0)) {
            _distributeETHRewardsToUserForToken(
                _from,
                address(lpTokenETH),
                lpTokenETH.balanceOf(_from),
                _from
            );
        }

        // Make sure that `_to` gets total accrued before transfer as post transferred anything owed will be wiped
        // @> VULN: no `if (_to != address(0))` guard here, unlike the `_from` branch above.
        // During a burn (withdrawETH), `_to == address(0)`, and this call
        // reaches `require(_recipient != address(0), "Zero address")` and reverts.
        _distributeETHRewardsToUserForToken(
            _to,
            address(lpTokenETH),
            lpTokenETH.balanceOf(_to),
            _to
        );
    }

    function afterTokenTransfer(address, address, uint256) external {}

    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTokenETH.totalSupply());
    }

    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    function _setClaimedToMax(address _user) internal {
        claimed[_user][address(lpTokenETH)] = (accumulatedETHPerLPShare * lpTokenETH.balanceOf(_user)) / PRECISION;
    }
}

/// @dev User orchestrator. Deploys the pool, deposits ETH, then attempts to
///      withdraw it (which requires burning GiantLP) — demonstrating the
///      burn always reverts because of the missing `_to != address(0)`
///      guard. Cheatcode-free — funded via `run()`'s msg.value.
contract Exploit {
    GiantMevAndFeesPool public pool; // nonce 1
    uint256 public constant DEPOSIT_AMOUNT = 4 ether;

    constructor() {
        pool = new GiantMevAndFeesPool(); // CREATE nonce 1
    }

    // Must be able to receive ETH: `beforeTokenTransfer`'s guarded `_from`
    // branch calls back into this contract with `_recipient.call{value:...}`
    // before reaching the unconditional `_to` branch that actually reverts.
    // Solidity fully unwinds that inner transfer when the outer call reverts,
    // so this has no effect on the demonstrated harm — it only lets execution
    // reach the real trigger instead of failing earlier for an unrelated
    // reason (no payable fallback).
    receive() external payable {}

    /// @notice Deposits ETH, then attempts (and fails) to withdraw it,
    ///         proving the user's funds are stuck. Funded via `run()`'s
    ///         msg.value (see `attackValueWei` in the Playground config).
    function run() external payable {
        require(msg.value == DEPOSIT_AMOUNT, "fund run() with DEPOSIT_AMOUNT");

        // 1) Deposit ETH — receives GiantLP 1:1, becomes withdrawable.
        pool.depositETH{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT);
        require(pool.lpTokenETH().balanceOf(address(this)) == DEPOSIT_AMOUNT, "should hold GiantLP");
        require(pool.idleETH() == DEPOSIT_AMOUNT, "deposit should be idle/withdrawable");

        // HARM: the user's own idle ETH cannot be withdrawn — ANY burn of
        // GiantLP reverts because beforeTokenTransfer's unconditional
        // zero-address distribute call chokes on _to == address(0).
        bool withdrawSucceeded = _tryWithdraw(DEPOSIT_AMOUNT);
        require(!withdrawSucceeded, "withdrawETH should have reverted (burn is broken)");

        // The funds remain fully idle and un-withdrawable — the pool holds
        // the ETH, the user holds the GiantLP claim, and neither side of the
        // withdraw path can complete.
        require(pool.idleETH() == DEPOSIT_AMOUNT, "idleETH unchanged: withdraw never completed");
        require(pool.lpTokenETH().balanceOf(address(this)) == DEPOSIT_AMOUNT, "GiantLP never burnt: user still holds the claim");
    }

    /// @dev try/catch wrapper so the underlying revert doesn't unwind run().
    function _tryWithdraw(uint256 _amount) internal returns (bool ok) {
        try pool.withdrawETH(_amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
