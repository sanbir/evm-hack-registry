//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IERC1155Upgradeable } from "../../dependencies/openzeppelin/v4_7_0/IERC1155Upgradeable.sol";

interface IERC1155PermitUpgradeable is IERC1155Upgradeable {
    function permit(
        address owner,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external;
}
