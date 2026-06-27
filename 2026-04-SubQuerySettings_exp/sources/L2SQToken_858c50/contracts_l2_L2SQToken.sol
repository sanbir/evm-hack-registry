// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { L2StandardERC20 } from '@eth-optimism/contracts/standards/L2StandardERC20.sol';

contract L2SQToken is L2StandardERC20 {
    constructor(
        address _l2Bridge,
        address _l1Token
    ) L2StandardERC20(_l2Bridge, _l1Token, 'SubQueryToken', 'SQT') {}
}
