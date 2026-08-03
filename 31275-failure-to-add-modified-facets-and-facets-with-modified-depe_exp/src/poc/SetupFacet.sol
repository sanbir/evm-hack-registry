// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "../beanstalk/ReentrancyGuard.sol";

/**
 * @title SetupFacet
 * @notice Harness-only facet used to establish the real pre-upgrade Silo state
 *         that Beanstalk builds through whitelisting (InitBipNewSilo) + deposits
 *         (LibTokenSilo.addDepositToAccount / LibSilo.mow). It writes the SAME
 *         AppStorage fields those real flows write:
 *           - whitelistToken:   s.ss[token].{milestoneSeason, stalkEarnedPerSeason, milestoneStem}
 *           - simulateDeposit:  s.a[account].mowStatuses[token].{lastStem, bdv}
 *           - setSeason:        s.season.current
 *         No vulnerability logic lives here; it only reproduces the starting
 *         state so the diamond-cut omission bug can be exercised deterministically.
 */
contract SetupFacet is ReentrancyGuard {
    function setSeason(uint32 current) external {
        s.season.current = current;
    }

    function whitelistToken(
        address token,
        uint32 stalkEarnedPerSeason,
        uint32 milestoneSeason_,
        int96 milestoneStem_
    ) external {
        s.ss[token].stalkEarnedPerSeason = stalkEarnedPerSeason;
        s.ss[token].milestoneSeason = milestoneSeason_; // non-zero => whitelisted
        s.ss[token].milestoneStem = milestoneStem_;
    }

    // Mirrors the mowStatus a pre-upgrade deposit+mow leaves for `account`.
    function simulateDeposit(
        address account,
        address token,
        int96 lastStem,
        uint128 bdv
    ) external {
        s.a[account].mowStatuses[token].lastStem = lastStem;
        s.a[account].mowStatuses[token].bdv = bdv;
    }

    // Views for assertions / diagnostics.
    function milestoneStem(address token) external view returns (int96) {
        return s.ss[token].milestoneStem;
    }

    function milestoneSeason(address token) external view returns (uint32) {
        return s.ss[token].milestoneSeason;
    }

    function currentSeason() external view returns (uint32) {
        return s.season.current;
    }
}
