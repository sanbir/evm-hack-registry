// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

interface IPausable {
    function pause() external;
    function unpause() external;
    function pauseSC(address _sc) external;
    function unpauseSC(address _sc) external;
    function isPaused(address _sc) external view returns (bool);

    //events
    event Paused(address indexed _sender);
    event Unpaused(address indexed _sender);
    event Paused(address indexed _sender, address indexed _sc);
    event Unpaused(address indexed _sender, address indexed _sc);
}
