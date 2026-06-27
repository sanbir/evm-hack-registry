// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "../../Supervisor.sol";
import "./libraries/L1BlockProviderProxy.sol";
import "./interfaces/iBVM_L1BlockNumber.sol";

/**
 * @title Minterest Supervisor Contract
 * @author Minterest
 */
contract Supervisor_Mantle is Supervisor {
    /// @dev Returns block number from L1 network.
    ///      Note! Block number from L1 returns with the delay
    function getBlockNumber() public view virtual override returns (uint256) {
        return iBVM_L1BlockNumber(L1BlockProviderProxy.iBVM_L1BlockNumber).getL1BlockNumber();
    }
}
