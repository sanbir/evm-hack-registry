// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-5: Borrow fee uses APY as per-second rate (Sherlock 2025-09, #63171)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: chargeTrueFeeRate multiplies annual rate by elapsed seconds
    without dividing by 365 days (~31_536_000), inflating fees ~31M×.
    Vulnerable line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    string public name = "COL";
    string public symbol = "COL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal rate curve: returns a fixed annual rate in Q64.64.
/// PoC rate ~0.228 APY → maxRateX64-style value used here as annual.
contract RateConfig {
    // ~0.228 * 2^64  (matches order of PoC takerRateX64 per-second before timeDiff)
    uint256 public constant ANNUAL_RATE_X64 = 4216398645419327111;

    function calculateRateX64(uint64 /*utilX64*/) external pure returns (uint256) {
        return ANNUAL_RATE_X64;
    }
}

/// @dev FeeWalker.chargeTrueFeeRate reduction — APY treated as per-second.
/// Source: Ammplify src/walkers/Fee.sol (chargeTrueFeeRate).
contract FeeWalker {
    RateConfig public immutable rateConfig;
    MockToken public immutable col;
    address public feeSink;

    uint256 public timestamp; // last fee accrual time (0 at open → full block.timestamp elapsed)
    uint256 public totalTLiq;
    uint256 public totalMLiq;
    uint256 public totalXBorrows;
    uint256 public lastTakerRateX64;
    uint256 public lastColXPaid;

    constructor(RateConfig rc, MockToken _col, address _sink) {
        rateConfig = rc;
        col = _col;
        feeSink = _sink;
    }

    function openBorrow(uint256 mLiq, uint256 tLiq, uint256 xBorrows) external {
        totalMLiq = mLiq;
        totalTLiq = tLiq;
        totalXBorrows = xBorrows;
        // Elapsed = 1 second regardless of absolute chain timestamp (playground may use unix time).
        // Keeps the vulnerable formula intact while avoiding multi-year accidental overcharge overflow.
        timestamp = block.timestamp > 0 ? block.timestamp - 1 : 0;
    }

    /// @notice Inlined chargeTrueFeeRate — multiplies APY by seconds without / 365 days.
    function chargeTrueFeeRate() external returns (uint256 colXPaid) {
        require(totalMLiq > 0, "no mLiq");
        // Convert to 256 for next mult
        uint256 timeDiff = uint128(block.timestamp) - timestamp; // Convert to 256 for next mult
        // FIX: takerRateX64 = FullMath.mulDiv(timeDiff, rateConfig.calculateRateX64(...), 365 days);
        uint256 takerRateX64 = timeDiff * rateConfig.calculateRateX64(
            uint64((totalTLiq << 64) / totalMLiq)
        ); // @> VULN: APY used as per-second rate — missing / 365 days; fees inflated ~31_536_000×
        lastTakerRateX64 = takerRateX64;

        // fee = borrows * rate / 2^64  (ceil-style not needed for demo)
        colXPaid = (totalXBorrows * takerRateX64) >> 64;
        lastColXPaid = colXPaid;

        // Charge borrower (msg.sender must approve)
        require(col.transferFrom(msg.sender, feeSink, colXPaid), "pay");
        timestamp = block.timestamp;
    }

    /// @dev Intended fee if annualized correctly for the same timeDiff.
    function correctFeeX(uint256 timeDiff) external view returns (uint256) {
        uint256 annual = rateConfig.calculateRateX64(0);
        uint256 correctRate = (timeDiff * annual) / 365 days;
        return (totalXBorrows * correctRate) >> 64;
    }
}

/// @dev Separate fee recipient so balance delta is visible.
contract FeeSink {}

/// CREATE order: token(1), rate(2), sink(3), walker(4)
contract Exploit {
    MockToken public token;
    RateConfig public rate;
    FeeSink public sink;
    FeeWalker public walker;

    uint256 public feePaid;
    uint256 public correctFee;
    uint256 public timeDiffUsed;

    constructor() {
        token = new MockToken(); // nonce 1
        rate = new RateConfig(); // nonce 2
        sink = new FeeSink(); // nonce 3
        walker = new FeeWalker(rate, token, address(sink)); // nonce 4
    }

    function run() external {
        // 50e18 borrowed against 100e18 maker / 50e18 taker util (as in PoC)
        uint256 principal = 50e18;
        walker.openBorrow(100e18, 50e18, principal);

        // Fund borrower (this) and approve fee payment (1s of buggy rate ~11e18 on 50e18 principal)
        token.mint(address(this), 10_000e18);
        token.approve(address(walker), type(uint256).max);

        uint256 beforeBal = token.balanceOf(address(this));
        uint256 sinkBefore = token.balanceOf(address(sink));
        walker.chargeTrueFeeRate();
        feePaid = beforeBal - token.balanceOf(address(this));
        require(token.balanceOf(address(sink)) - sinkBefore == feePaid, "sink got fees");

        timeDiffUsed = 1; // open was set to block.timestamp - 1
        require(walker.lastTakerRateX64() > 0, "need positive rate");
        correctFee = walker.correctFeeX(timeDiffUsed);

        // Harm: fee is catastrophically larger than annualized intent
        require(feePaid > correctFee, "must overcharge vs annualized");
        // Even for 1 second, paid is huge fraction of principal; correct is dust
        require(feePaid > principal / 10, "overcharge is material (>10% principal)");
        // Amplification roughly 31_536_000 (= 365 days)
        if (correctFee > 0) {
            require(feePaid / correctFee > 1_000_000, "inflated by orders of magnitude");
        } else {
            require(feePaid > 1e18, "large absolute overcharge");
        }

        require(feePaid == walker.lastColXPaid(), "accounting");
    }
}
