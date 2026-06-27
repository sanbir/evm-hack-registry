// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum ExchangeMode {
    // normal exchange
    normalExchange,
    // repeat exchange
    repeatExchange,
    // normal unstake
    normalUnstake,
    // repeat unstake
    repeatUnstake
}

enum SwitchType {
    // normal release switch
    normalReleaseSwitch,
    // repeat release switch
    repeatReleaseSwitch,
    // normal unstake release switch
    normalUnstakeReleaseSwitch,
    // repeat unstake release switch
    repeatUnstakeReleaseSwitch
}

struct VestingSchedule {
    // start
    uint256 start;
    // beneficiary of tokens after they are released
    address beneficiary;
    // contract amount
    uint256 amount;
    // released
    uint256 released;
}

struct Info {
    // Total periods
    uint256 periods;
    // interval
    uint256 interval;
}

interface ILinearVesting {
    function addLinearVesting(address beneficiary, uint256 amount) external;

    function addLinearVesting(
        bytes32 txHash,
        address beneficiary,
        uint256 amount,
        ExchangeMode mode
    ) external;

    function release(uint256 index) external;

    function getReleasableAmount(uint256 index) external view returns (uint256);
}
