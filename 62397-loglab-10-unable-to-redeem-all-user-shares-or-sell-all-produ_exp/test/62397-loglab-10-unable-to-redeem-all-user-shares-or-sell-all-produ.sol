// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BasisOS BasisStrategy LOGLAB-10 - Hexens, Nov 2024.
    Closing the hedge sets sizeDeltaInTokens to type(uint256).max.
    _adjustPosition then clamps that sentinel to decreaseSizeMax.
    _afterDecreasePosition only swaps in the agent's real fill when the
    stored request is still type(uint256).max. A lower max makes the fill
    look short, so the shortfall fraction of the redemption is bought back
    on the spot and the redeemer is paid the rest.

    Numbers: position and sale proceeds are 1,000. decreaseSizeMax is 10,000.
    The agent closes the real 1,000. Deviation is 1,000 - 10,000 = -9,000.
    Bought back = 1,000 * 9,000 / 10,000 = 900. Redeemer receives 100.
    If decreaseSizeMax is type(uint256).max the sentinel survives and the
    redeemer receives 1,000.
*/

contract Shortfall {
    string public symbol = "LOCKED";
    uint8 public constant decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amount) external {
        _bal[to] = _bal[to] + amount;
    }
}

contract Asset {
    string public symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address account) external view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amount) external {
        _bal[to] = _bal[to] + amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _bal[msg.sender] = _bal[msg.sender] - amount;
        _bal[to] = _bal[to] + amount;
        return true;
    }
}

contract SpotManager {
    uint256 public calls;
    uint256 public lastBuy;
    uint256 public exposure;

    function closeAll(BasisStrategy strategy, uint256 assetDelta, uint256 productDelta) external {
        calls = calls + 1;
        strategy.spotSellCallback(assetDelta, productDelta);
    }

    function buy(uint256 amount) external {
        lastBuy = amount;
        exposure = exposure + amount;
    }
}

contract HedgeManager {
    uint256 public positionSize;
    uint256 public decreaseSizeMin;
    uint256 public decreaseSizeMax;

    function setBook(uint256 position, uint256 maxDecrease) external {
        positionSize = position;
        decreaseSizeMin = 1;
        decreaseSizeMax = maxDecrease;
    }

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max) {
        return (decreaseSizeMin, decreaseSizeMax);
    }
}

contract BasisStrategy {
    uint256 public constant THRESHOLD_BPS = 100;
    address public constant REDEEMER = 0x000000000000000000000000000000000000bEEF;

    Asset public immutable asset;
    SpotManager public immutable spot;
    HedgeManager public immutable hedge;

    uint256 public vaultSupply;
    bool public isRebalanceDown;
    address public redeemer;
    uint256 public sentinelArmed;
    uint256 public recordedMax;
    uint256 public clampedSize;
    uint256 public storedCollateral;
    uint256 public pendingAssets;
    uint256 public productSeen;
    uint256 public pendingDecreaseCollateral;
    uint256 public missedSentinel;
    uint256 public usedSentinel;
    uint256 public exceedsFlag;
    int256 public deviationStored;
    uint256 public assetsReverted;
    uint256 public paidToRedeemer;

    constructor(Asset _asset, SpotManager _spot, HedgeManager _hedge) {
        asset = _asset;
        spot = _spot;
        hedge = _hedge;
    }

    function redeemerOf() external pure returns (address) {
        return REDEEMER;
    }

    function runClose(uint256 decreaseMax, uint256 proceeds) external {
        redeemer = REDEEMER;
        hedge.setBook(proceeds, decreaseMax);
        asset.mint(address(this), proceeds);
        spot.closeAll(this, proceeds, proceeds);
        afterDecrease(proceeds, proceeds);
    }

    // Quoted spotSellCallback close-all branch.
    function spotSellCallback(uint256 assetDelta, uint256 productDelta) external {
        require(msg.sender == address(spot), "spot");
        uint256 sizeDeltaInTokens;
        uint256 collateralDeltaAmount;
        if (!isRebalanceDown) {
            if (vaultSupply == 0 || spot.exposure() == 0) {
                sizeDeltaInTokens = type(uint256).max;
                collateralDeltaAmount = type(uint256).max;
                pendingDecreaseCollateral = 0;
                sentinelArmed = sizeDeltaInTokens;
                productSeen = productDelta;
            }
        }
        _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false);
        pendingAssets = assetDelta;
    }

    function _adjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease) internal {
        if (sizeDeltaInTokens > 0) {
            uint256 min;
            uint256 max;
            if (isIncrease) {
                min = 0;
                max = 0;
            } else {
                (min, max) = hedge.decreaseSizeMinMax();
            }
            recordedMax = max;
            // @> VULN: the close-all sentinel is clamped to decreaseSizeMax, so it is no longer type(uint256).max
            clampedSize = _clamp(min, sizeDeltaInTokens, max);
        }
        storedCollateral = collateralDeltaAmount;
    }

    function _clamp(uint256 min, uint256 value, uint256 max) internal pure returns (uint256) {
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }

    // Quoted _afterDecreasePosition. Negative size deviation buys the shortfall back.
    function afterDecrease(uint256 responseSize, uint256 responseCollateral) public {
        uint256 requestSize = clampedSize;
        uint256 requestCollateral = storedCollateral;
        if (requestSize == type(uint256).max) {
            requestSize = responseSize;
            requestCollateral = responseCollateral;
            usedSentinel = requestCollateral > 0 ? 1 : 1;
        } else {
            missedSentinel = requestSize;
        }
        uint256 pending = pendingAssets;
        (bool exceeds, int256 deviation) = _checkDeviation(responseSize, requestSize, THRESHOLD_BPS);
        exceedsFlag = exceeds ? 1 : 0;
        deviationStored = deviation;
        uint256 revertedAmt;
        if (exceeds && deviation < 0) {
            uint256 sizeDeviationAbs = uint256(-deviation);
            if (sizeDeviationAbs == requestSize) {
                revertedAmt = pending;
            } else {
                revertedAmt = pending * sizeDeviationAbs / requestSize;
            }
            if (revertedAmt > 0) {
                assetsReverted = revertedAmt;
                asset.transfer(address(spot), revertedAmt);
                spot.buy(revertedAmt);
            }
        }
        uint256 left = pending - assetsReverted;
        paidToRedeemer = left;
        if (left > 0) {
            asset.transfer(redeemer, left);
        }
    }

    // response - request. Negative means the agent filled less than the stored request.
    function _checkDeviation(uint256 response, uint256 request, uint256 thresholdBps)
        internal
        pure
        returns (bool exceeds, int256 deviation)
    {
        if (request == 0) return (false, 0);
        if (response >= request) {
            deviation = int256(response - request);
        } else {
            deviation = -int256(request - response);
        }
        uint256 absDev = response >= request ? response - request : request - response;
        exceeds = absDev * 10_000 / request > thresholdBps;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant PROCEEDS = 1_000 ether;
    uint256 public constant DECREASE_MAX = 10_000 ether;

    Shortfall public short;
    Asset public asset;
    SpotManager public spot;
    HedgeManager public hedge;
    BasisStrategy public strategy;

    uint256 public started;
    uint256 public spotGot;
    uint256 public userGot;
    uint256 public locked;

    constructor() {
        short = new Shortfall();
        asset = new Asset();
        spot = new SpotManager();
        hedge = new HedgeManager();
        strategy = new BasisStrategy(asset, spot, hedge);
    }

    function run() external {
        started = 1;
        strategy.runClose(DECREASE_MAX, PROCEEDS);
        spotGot = asset.balanceOf(address(spot));
        userGot = asset.balanceOf(strategy.redeemerOf());
        locked = PROCEEDS - userGot;
        short.mint(SINK, locked);
        require(strategy.sentinelArmed() == type(uint256).max, "sentinel");
        require(strategy.clampedSize() == DECREASE_MAX, "clamped");
        require(strategy.missedSentinel() == DECREASE_MAX, "missed");
        require(strategy.assetsReverted() == 900 ether, "reverted");
        require(strategy.paidToRedeemer() == 100 ether, "paid");
        require(spotGot == 900 ether, "spot");
        require(userGot == 100 ether, "user");
        require(locked == 900 ether, "locked");
        require(short.balanceOf(SINK) == 900 ether, "marker");
        require(spot.lastBuy() == 900 ether, "buy");
    }
}
