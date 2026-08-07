// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

/// @dev Minimal REAL ERC20 standing in for the bridged yToken asset. It is a
/// genuine transferable token (so `Common.isContract(token)` holds and the
/// bridge's unlock is a real balance movement). It is NOT the contract the
/// finding is about — the vulnerable contract is `BridgeCCIP`.
contract BridgeToken {
    string public name = "YieldFi yToken";
    string public symbol = "yUSD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "!balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
