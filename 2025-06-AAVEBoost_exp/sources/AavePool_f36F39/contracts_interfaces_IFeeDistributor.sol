//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeDistributor {
    ////
    /// fee distribution interface to be implemented
    /// by all pools so that they conform to the
    /// fee Distributor implementation
    ///

    event WithdrawFees(address indexed sender, uint256 feesReceived, uint256 timestamp);

    function withdrawFees() external returns (uint256 feeAmount);
}
