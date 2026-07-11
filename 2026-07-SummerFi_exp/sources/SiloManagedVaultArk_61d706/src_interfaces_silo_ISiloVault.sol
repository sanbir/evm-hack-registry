// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ISiloVault is IERC4626 {
    function INCENTIVES_MODULE() external view returns (address);
}
