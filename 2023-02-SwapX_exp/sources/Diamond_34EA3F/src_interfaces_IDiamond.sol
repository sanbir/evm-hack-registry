// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

interface IDiamond {
    function poolBurnFrom(address _address, uint256 _amount) external;

    function poolMint(address _address, uint256 m_amount) external;
}
