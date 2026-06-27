//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IRoyal1155LDA {

    function tierBalanceOf(
        uint128 tierId,
        address owner
    )
        external
        view
        returns (uint256);

    function getOwnedTokens(
        uint128 tierId,
        address owner
    )
        external
        view
        returns (uint256[] memory);

    function getTierTotalSupply(
        uint128 tierId
    )
        external
        view
        returns (uint256);

    function tierExists(
        uint128 tierId
    )
        external
        view
        returns (bool);

    function mintable(
        uint128 tierId
    )
        external
        view
        returns (bool);
}
