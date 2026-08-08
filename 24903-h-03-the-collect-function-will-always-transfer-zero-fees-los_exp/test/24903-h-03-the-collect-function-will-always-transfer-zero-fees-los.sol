// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Timeswap V2 — [H-03] The collect() function will always TRANSFER ZERO
    fees, losing _feesPositions without receiving fees
    (0xcm, Code4rena 2023-01-timeswap, finding #24903)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: TimeswapV2LiquidityToken.collect() calls
    ITimeswapV2Pool.transferFees(...) with long0Fees/long1Fees/shortFees
    BEFORE those values are computed by getFees(). The locals default to 0,
    so the pool always transfers zero fees. Immediately after, getFees()
    loads the real amounts and burn() permanently destroys the fee position
    — so the user burns non-zero _feesPositions and receives nothing.

    The vulnerable collect() body is preserved with the order of operations
    intact (@> VULN on the premature transferFees line). Factories, guards,
    and fee-growth math are reduced to minimal mocks that seed a non-zero
    fee position so the burn-without-payout harm is measurable.
//////////////////////////////////////////////////////////////////////////*/

struct CollectParam {
    address token0;
    address token1;
    uint256 strike;
    uint256 maturity;
    address to;
    uint256 long0FeesDesired;
    uint256 long1FeesDesired;
    uint256 shortFeesDesired;
}

/// @dev Minimal fee-position accounting (getFees/burn/mint) matching FeesPositionLibrary.
struct FeesPosition {
    uint256 long0Fees;
    uint256 long1Fees;
    uint256 shortFees;
}

/// @notice Pool that holds fee tokens and honors transferFees. Tracks how
///         much was actually transferred so the PoC can prove zero payout.
contract MockPool {
    mapping(address => uint256) public long0Bal; // recipient => long0 received
    mapping(address => uint256) public long1Bal;
    mapping(address => uint256) public shortBal;

    // Bookkeeping only — the synthetic seeds these so transferFees has
    // something to move when non-zero amounts are requested.
    uint256 public long0Reserve;
    uint256 public long1Reserve;
    uint256 public shortReserve;

    function seed(uint256 l0, uint256 l1, uint256 s) external {
        long0Reserve = l0;
        long1Reserve = l1;
        shortReserve = s;
    }

    function transferFees(
        uint256, /*strike*/
        uint256, /*maturity*/
        address to,
        uint256 long0Fees,
        uint256 long1Fees,
        uint256 shortFees
    ) external {
        // Real pool would pull from its fee reserves. Here we just credit
        // the recipient so the PoC can measure the transfer amount.
        long0Bal[to] += long0Fees;
        long1Bal[to] += long1Fees;
        shortBal[to] += shortFees;
        // subtract from reserve if enough (zero is always "enough")
        if (long0Fees > 0) long0Reserve -= long0Fees;
        if (long1Fees > 0) long1Reserve -= long1Fees;
        if (shortFees > 0) shortReserve -= shortFees;
    }
}

/// @notice Reduced TimeswapV2LiquidityToken.collect — order of ops VERBATIM
///         from the audited source (transferFees BEFORE getFees).
contract TimeswapV2LiquidityToken {
    MockPool public pool;

    // single-position simplification: one id, one holder fee position
    mapping(address => FeesPosition) public feesOf;
    mapping(address => bool) public burned; // true once collect burned a non-zero position

    constructor(MockPool _pool) {
        pool = _pool;
    }

    /// @dev Seed a non-zero fees position for a user (stands in for accrued fees).
    function seedFees(address user, uint256 l0, uint256 l1, uint256 s) external {
        feesOf[user] = FeesPosition(l0, l1, s);
    }

    function getFeesOf(address user) external view returns (uint256, uint256, uint256) {
        FeesPosition memory f = feesOf[user];
        return (f.long0Fees, f.long1Fees, f.shortFees);
    }

    /// @notice Verbatim order from TimeswapV2LiquidityToken.collect (audited):
    ///         transferFees is called with the still-zero locals, then getFees
    ///         computes the real amounts, then burn destroys them.
    function collect(CollectParam calldata param)
        external
        returns (uint256 long0Fees, uint256 long1Fees, uint256 shortFees)
    {
        // transfer the fees amount to the recipient
        // FIX: move this call AFTER getFees() so the computed amounts are transferred
        pool.transferFees(param.strike, param.maturity, param.to, long0Fees, long1Fees, shortFees); // @> VULN: long0Fees/long1Fees/shortFees still 0

        // (long0Fees, long1Fees, shortFees) = _feesPositions[id][msg.sender].getFees(...)
        FeesPosition storage fp = feesOf[msg.sender];
        long0Fees = fp.long0Fees < param.long0FeesDesired ? fp.long0Fees : param.long0FeesDesired;
        long1Fees = fp.long1Fees < param.long1FeesDesired ? fp.long1Fees : param.long1FeesDesired;
        shortFees = fp.shortFees < param.shortFeesDesired ? fp.shortFees : param.shortFeesDesired;

        // burn the desired fees from the fees position
        fp.long0Fees -= long0Fees;
        fp.long1Fees -= long1Fees;
        fp.shortFees -= shortFees;

        if (long0Fees != 0 || long1Fees != 0 || shortFees != 0) {
            burned[msg.sender] = true;
        }
    }
}

/// @notice Seeds a non-zero fee position, calls collect(), and proves:
///         (1) pool transferred 0 fees, (2) fee position was fully burned.
contract Exploit {
    MockPool public pool; // CREATE nonce 1
    TimeswapV2LiquidityToken public lt; // CREATE nonce 2

    address public constant RECIPIENT = address(0xBEEF);

    uint256 public constant L0 = 100 ether;
    uint256 public constant L1 = 50 ether;
    uint256 public constant SHORT = 25 ether;

    constructor() {
        pool = new MockPool(); // 1
        lt = new TimeswapV2LiquidityToken(pool); // 2
        // Seed pool reserves and the liquidity-token fee position.
        pool.seed(L0, L1, SHORT);
        lt.seedFees(address(this), L0, L1, SHORT);
    }

    function run() external {
        // Pre-state: user holds non-zero fees; recipient has received nothing.
        (uint256 a0, uint256 a1, uint256 as_) = lt.getFeesOf(address(this));
        require(a0 == L0 && a1 == L1 && as_ == SHORT, "seed missing");
        require(pool.long0Bal(RECIPIENT) == 0, "recipient not empty");

        // Collect full desired amounts.
        CollectParam memory p = CollectParam({
            token0: address(0xA0),
            token1: address(0xA1),
            strike: 1e18,
            maturity: 2_000_000_000,
            to: RECIPIENT,
            long0FeesDesired: type(uint256).max,
            long1FeesDesired: type(uint256).max,
            shortFeesDesired: type(uint256).max
        });
        (uint256 c0, uint256 c1, uint256 cs) = lt.collect(p);

        // getFees DID compute the real non-zero amounts...
        require(c0 == L0 && c1 == L1 && cs == SHORT, "getFees should return real amounts");

        // ...but transferFees ran with zeros, so recipient got nothing.
        require(pool.long0Bal(RECIPIENT) == 0, "harm: expected zero long0 transfer");
        require(pool.long1Bal(RECIPIENT) == 0, "harm: expected zero long1 transfer");
        require(pool.shortBal(RECIPIENT) == 0, "harm: expected zero short transfer");

        // ...and the fee position was burned to zero.
        (uint256 b0, uint256 b1, uint256 bs) = lt.getFeesOf(address(this));
        require(b0 == 0 && b1 == 0 && bs == 0, "fee position not burned");
        require(lt.burned(address(this)), "burn flag not set");
    }
}
