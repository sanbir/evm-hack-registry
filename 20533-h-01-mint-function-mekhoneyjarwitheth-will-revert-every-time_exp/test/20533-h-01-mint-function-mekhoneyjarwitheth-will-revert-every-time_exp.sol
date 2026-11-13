// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./20533-h-01-mint-function-mekhoneyjarwitheth-will-revert-every-time.sol";

contract HoneyBoxFixed {
    error WrongAmount_ETH(uint256 expected, uint256 paid);
    uint256 public constant PRICE = 0.1 ether;
    uint256 public minted;

    function mekHoneyJarWithETH(uint8, uint256 amount_) external payable returns (uint256) {
        uint256 expected = PRICE * amount_;
        if (msg.value != expected) revert WrongAmount_ETH(expected, msg.value);
        minted += amount_;
        return minted;
    }
}

contract Finding20533Test is Test {
    function test_exploit_eth_mint_reverts_and_mints_nothing() public {
        Exploit e = new Exploit();
        e.run{value: 0.1 ether}();
        assertEq(e.box().minted(), 0, "no jar");
        assertEq(address(e.box()).balance, 0, "box holds no ETH");
        assertEq(address(e).balance, 0.1 ether, "buyer still holds the price");
    }

    function test_control_payable_mint_takes_the_price() public {
        HoneyBoxFixed box = new HoneyBoxFixed();
        uint256 id = box.mekHoneyJarWithETH{value: 0.1 ether}(1, 1);
        assertEq(id, 1, "minted id");
        assertEq(box.minted(), 1, "one jar");
        assertEq(address(box).balance, 0.1 ether, "price received");
    }
}
