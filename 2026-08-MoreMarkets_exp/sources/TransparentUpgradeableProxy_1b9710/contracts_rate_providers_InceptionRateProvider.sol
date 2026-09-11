// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IRateProvider.sol";
import "../interfaces/IInceptionRatioFeed.sol";

/// @author The InceptionLRT team
/// @title The InceptionRateProvider contract
/// @notice Inheritable standard rate provider interface.
abstract contract InceptionRateProvider is IRateProvider {
    //using SafeMath for uint256;

    IInceptionRatioFeed public ratioFeed;
    address internal _asset;

    constructor(address ratioFeedAddress, address assetAddress) payable {
        ratioFeed = IInceptionRatioFeed(ratioFeedAddress);
        _asset = assetAddress;
    }

    function getRate() external view override returns (uint256) {
        return
            safeFloorMultiplyAndDivide(
                1e18,
                1e18,
                ratioFeed.getRatioFor(_asset)
            );
    }

    function safeFloorMultiplyAndDivide(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        // uint256 remainder = a.mod(c);
        // uint256 result = a.div(c);
        // bool safe;
        // (safe, result) = result.tryMul(b);
        // if (!safe) {
        //     return
        //         0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        // }
        // (safe, result) = result.tryAdd(remainder.mul(b).div(c));
        // if (!safe) {
        //     return
        //         0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        // }
        return 0;
    }
}
