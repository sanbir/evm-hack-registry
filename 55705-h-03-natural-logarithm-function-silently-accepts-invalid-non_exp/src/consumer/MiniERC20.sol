// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal real ERC20 (the opaque "settlement asset" boundary). Full transfer
/// accounting so the harm is a genuine token balance delta, not a mock.
contract MiniERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _n, string memory _s, uint8 _d) {
        name = _n; symbol = _s; decimals = _d;
    }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }
    function approve(address sp, uint256 amt) external returns (bool) { allowance[msg.sender][sp] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { _xfer(msg.sender, to, amt); return true; }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        _xfer(f, to, amt); return true;
    }
    function _xfer(address f, address to, uint256 amt) internal {
        require(balanceOf[f] >= amt, "balance");
        balanceOf[f] -= amt; balanceOf[to] += amt;
    }
}
