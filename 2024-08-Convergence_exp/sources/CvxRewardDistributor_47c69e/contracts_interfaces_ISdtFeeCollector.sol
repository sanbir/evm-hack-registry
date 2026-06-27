// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISdtFeeCollector {
    function rootFees() external returns (uint256);

    function withdrawToken(IERC20[] calldata _tokens) external;

    function withdrawSdt() external;

    struct Fees {
        address receiver;
        uint96 feePercentage;
    }
    function feesRepartition(uint256 index) external view returns (Fees memory);
}
