// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

// usefull for describing selectors, shouldn't be used as an actaul interface
interface InLogicBlacklistedMethodsWithoutData {
    function increaseAllowance(
        address spender,
        uint256 increment
    ) external returns (bool);

    function decreaseAllowance(
        address spender,
        uint256 decrement
    ) external returns (bool);

    function approve(address spender, uint256 value) external returns (bool);

    function mint(address to, uint256 value) external returns (bool);

    function burn(uint256 value) external;

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    // ERC-777
    function authorizeOperator(address operator) external;

    function revokeOperator(address operator) external;

    // ERC-1363
    function approveAndCall(
        address spender,
        uint256 value
    ) external returns (bool);

    function transferFromAndCall(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
}

// we can't access .selector of methods if methods are overloaded.
// more info here: https://github.com/ethereum/solidity/issues/3556
interface InLogicBlacklistedMethodsWithData {
    // ERC-1363
    function approveAndCall(
        address spender,
        uint256 value,
        bytes calldata data
    ) external returns (bool);

    function transferFromAndCall(
        address from,
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool);
}
