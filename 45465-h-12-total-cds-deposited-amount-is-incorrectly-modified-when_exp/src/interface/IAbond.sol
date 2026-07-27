// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

struct State {
    uint256 cumulativeRate;
    uint128 ethBacked;
    uint128 aBondBalance;
}

interface IABONDToken {
    function balanceOf(address account) external view returns (uint256);

    function mint(
        address to,
        uint64 index,
        uint256 amount
    ) external returns (bool);

    function burnFromUser(address to, uint256 amount) external returns (bool);

    function burnFrom(address account, uint256 amount) external;

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function setAbondData(
        address user,
        uint64 index,
        uint128 ethBacked,
        uint128 cumulativeRate
    ) external;

    function userStates(address user) external view returns (State memory);

    function userStatesAtDeposits(
        address user,
        uint64 index
    ) external view returns (State memory);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}
