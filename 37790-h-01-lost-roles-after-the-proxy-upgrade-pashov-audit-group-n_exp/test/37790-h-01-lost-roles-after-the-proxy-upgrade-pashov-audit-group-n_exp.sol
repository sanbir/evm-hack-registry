// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StoreV1, StoreFixed, DiamondProxy, Manager, ROLES_MANAGER} from "./37790-h-01-lost-roles-after-the-proxy-upgrade-pashov-audit-group-n.sol";

contract Finding37790Test is Test {
    function test_exploit_upgrade_drops_role_and_bricks_gate() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.roleBefore(), "role before");
        assertFalse(e.roleAfter(), "role after");
        assertTrue(e.gatedBricked(), "gate");
    }

    function test_control_mapping_kept_at_slot_2() public {
        StoreV1 v1 = new StoreV1();
        StoreFixed fixedImpl = new StoreFixed();
        DiamondProxy proxy = new DiamondProxy();
        Manager manager = new Manager();
        proxy.upgradeTo(address(v1));
        StoreV1(address(proxy)).grantRole(address(manager), ROLES_MANAGER);
        proxy.upgradeTo(address(fixedImpl));
        assertTrue(StoreFixed(address(proxy)).hasRole(address(manager), ROLES_MANAGER), "fixed keeps role");
        assertTrue(manager.trySet(address(proxy), address(0x1234)), "fixed gate works");
    }
}
