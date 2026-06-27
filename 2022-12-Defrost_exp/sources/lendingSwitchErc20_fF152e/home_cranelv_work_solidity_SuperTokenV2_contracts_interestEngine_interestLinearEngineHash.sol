// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;
import "./baseInterestEngineHash.sol";
import "../modules/SignedSafeMath.sol";
/**
 * @title linear interest engine.
 * @dev calculate interest on assets,linear interest rate.
 *
 */
contract interestLinearEngineHash is baseInterestEngineHash{
    using SignedSafeMath for int256;
    using SafeMath for uint256;
    function calAccumulatedRate(uint256 baseRate,uint256 timeSpan,
        int256 _interestRate,uint256 _interestInterval)internal override pure returns (uint256){
        int256 newRate = _interestRate.mul(int256(timeSpan/_interestInterval));
        if (newRate>=0){
            return baseRate.add(uint256(newRate));
        }else{
            return baseRate.sub(uint256(-newRate));
        }
    }
}