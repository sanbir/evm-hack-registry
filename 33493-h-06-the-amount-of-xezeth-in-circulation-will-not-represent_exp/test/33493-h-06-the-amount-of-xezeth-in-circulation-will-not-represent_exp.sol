// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// REAL audited Renzo bridge source (2024-04-renzo, commit b5b5b76), unmodified.
import {xRenzoDeposit} from "../src/selected/Bridge/L2/xRenzoDeposit.sol";
import {xRenzoBridge} from "../src/selected/Bridge/L1/xRenzoBridge.sol";
import {XERC20} from "../src/selected/Bridge/xERC20/contracts/XERC20.sol";
import {XERC20Lockbox} from "../src/selected/Bridge/xERC20/contracts/XERC20Lockbox.sol";

import {IConnext} from "../src/selected/Bridge/Connext/core/IConnext.sol";
import {IRenzoOracleL2} from "../src/selected/Bridge/L2/Oracle/IRenzoOracleL2.sol";
import {IXReceiver} from "../src/selected/Bridge/Connext/core/IXReceiver.sol";
import {IRestakeManager} from "../src/selected/IRestakeManager.sol";
import {IXERC20Lockbox} from "../src/selected/Bridge/xERC20/interfaces/IXERC20Lockbox.sol";
import {IRateProvider} from "../src/selected/RateProvider/IRateProvider.sol";
import {IRoleManager} from "../src/selected/Permissions/IRoleManager.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

/*//////////////////////////////////////////////////////////////
        Minimal-but-real supporting contracts (opaque tokens
        + the ONLY legitimate mock: the cross-chain messenger).
//////////////////////////////////////////////////////////////*/

/// Plain 18-decimal ERC20 used for opaque tokens (ezETH, nextWETH collateral, LINK).
contract MintableERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Real WETH semantics (ETH-backed): deposit mints, withdraw burns + returns ETH.
contract WETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        _burn(msg.sender, wad);
        (bool ok, ) = payable(msg.sender).call{value: wad}("");
        require(ok, "ETH send failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// Thin harness around the REAL audited RenzoOracle.calculateMintAmount math.
/// The EigenLayer TVL plumbing that the real RestakeManager uses to derive
/// `totalTVL` is opaque restaking infrastructure and is NOT part of this finding;
/// the ezETH mint-rate formula (the L1 valuation the bug hinges on) is preserved
/// verbatim below, so the L1 leg mints ezETH at the REAL current-valuation rate.
contract RestakeManagerStub {
    uint256 internal constant SCALE_FACTOR = 10 ** 18;

    MintableERC20 public ezETH;
    uint256 public totalTVL;

    constructor(MintableERC20 _ezETH) {
        ezETH = _ezETH;
    }

    /// Establish an initial ezETH supply and matching TVL (price = TVL/supply).
    function seed(uint256 ethValue) external {
        totalTVL += ethValue;
        ezETH.mint(msg.sender, ethValue);
    }

    /// Simulate protocol reward accrual: TVL rises with no new supply => ezETH price rises.
    function accrueRewards(uint256 ethValue) external {
        totalTVL += ethValue;
    }

    /// Mirror of RestakeManager.depositETH(): mint ezETH at the CURRENT valuation.
    function depositETH() external payable {
        uint256 ezETHToMint = _calculateMintAmount(totalTVL, msg.value, ezETH.totalSupply());
        totalTVL += msg.value;
        ezETH.mint(msg.sender, ezETHToMint);
    }

    // Verbatim from audited contracts/Oracle/RenzoOracle.sol:calculateMintAmount.
    function _calculateMintAmount(
        uint256 _currentValueInProtocol,
        uint256 _newValueAdded,
        uint256 _existingEzETHSupply
    ) internal pure returns (uint256) {
        if (_currentValueInProtocol == 0 || _existingEzETHSupply == 0) {
            return _newValueAdded;
        }
        uint256 inflationPercentaage = (SCALE_FACTOR * _newValueAdded) /
            (_currentValueInProtocol + _newValueAdded);
        uint256 newEzETHSupply = (_existingEzETHSupply * SCALE_FACTOR) /
            (SCALE_FACTOR - inflationPercentaage);
        uint256 mintAmount = newEzETHSupply - _existingEzETHSupply;
        require(mintAmount != 0, "InvalidTokenAmount");
        return mintAmount;
    }
}

/// The ONLY mocked component: the opaque cross-chain messenger (Connext).
/// It faithfully reproduces the observable transport behaviour the real
/// contracts depend on: L2 swap (WETH->nextWETH) and xcall (deliver the
/// canonical wETH to the L1 target and invoke xReceive). It carries NONE of
/// the vulnerable accounting.
contract MockConnext {
    MintableERC20 public nextWETH; // L2 collateral token minted on swap
    WETH public wethL1; // canonical asset delivered to the L1 bridge

    constructor(MintableERC20 _nextWETH, WETH _wethL1) payable {
        nextWETH = _nextWETH;
        wethL1 = _wethL1;
    }

    // L2: xRenzoDeposit swaps depositToken(WETH) -> collateralToken(nextWETH) 1:1.
    function swapExact(
        bytes32,
        uint256 amountIn,
        address assetIn,
        address assetOut,
        uint256,
        uint256
    ) external payable returns (uint256) {
        IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        MintableERC20(assetOut).mint(msg.sender, amountIn);
        return amountIn;
    }

    // L2->L1 transport: pull nextWETH from the sweeper, deliver ETH-backed wETH to
    // the L1 bridge target, then invoke its xReceive exactly as Connext would.
    function xcall(
        uint32 _destination,
        address _to,
        address _asset,
        address _delegate,
        uint256 _amount,
        uint256,
        bytes calldata _callData
    ) external payable returns (bytes32) {
        IERC20(_asset).transferFrom(msg.sender, address(this), _amount);
        wethL1.deposit{value: _amount}();
        wethL1.transfer(_to, _amount);
        IXReceiver(_to).xReceive(bytes32(0), _amount, address(wethL1), _delegate, _destination, _callData);
        return bytes32(0);
    }

    receive() external payable {}
}

/// Minimal delegatecall proxy so the real Initializable contracts can be
/// `initialize`d (their constructors call `_disableInitializers`).
contract DelegateProxy {
    address public immutable implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    fallback() external payable {
        address target = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                            THE POC
//////////////////////////////////////////////////////////////*/

contract PoC_33493 is Test {
    // Real contracts
    XERC20 xezETH; // canonical xezETH (XERC20)
    MintableERC20 ezETH; // L1 ezETH (plain ERC20)
    WETH wethL2; // L2 deposit token
    WETH wethL1; // L1 canonical wETH
    MintableERC20 nextWETH; // L2 collateral token
    MintableERC20 linkToken;
    RestakeManagerStub restakeManager;
    XERC20Lockbox lockbox;
    xRenzoDeposit deposit_;
    xRenzoBridge bridge;
    MockConnext connext;

    address constant ALICE = address(0xA11CE);

    function _proxify(address impl) internal returns (address) {
        return address(new DelegateProxy(impl));
    }

    function setUp() public {
        // ---- tokens ----
        xezETH = XERC20(_proxify(address(new XERC20())));
        xezETH.initialize("xezETH", "xezETH", address(this)); // factory/owner = this

        ezETH = new MintableERC20("ezETH", "ezETH");
        wethL2 = new WETH();
        wethL1 = new WETH();
        nextWETH = new MintableERC20("nextWETH", "nextWETH");
        linkToken = new MintableERC20("LINK", "LINK");

        // ---- L1 restake manager (real mint-rate math), seeded to price 1.0 ----
        restakeManager = new RestakeManagerStub(ezETH);
        restakeManager.seed(100 ether); // TVL 100, supply 100 -> ezETH price = 1.0

        // ---- L1 lockbox (ezETH <-> xezETH, 1:1) ----
        lockbox = XERC20Lockbox(payable(_proxify(address(new XERC20Lockbox()))));
        lockbox.initialize(address(xezETH), address(ezETH), false);
        xezETH.setLockbox(address(lockbox)); // lockbox can mint/burn xezETH w/o limits

        // ---- cross-chain messenger mock, funded with ETH to back delivered wETH ----
        connext = new MockConnext(nextWETH, wethL1);
        vm.deal(address(connext), 10 ether);

        // ---- L1 bridge (real) ----
        bridge = xRenzoBridge(payable(_proxify(address(new xRenzoBridge()))));
        bridge.initialize(
            IERC20(address(ezETH)),
            IERC20(address(xezETH)),
            IRestakeManager(address(restakeManager)),
            IERC20(address(wethL1)),
            IXERC20Lockbox(address(lockbox)),
            IConnext(address(connext)),
            IRouterClient(address(0xC1)), // unused by xReceive
            IRateProvider(address(0xC2)), // unused by xReceive
            LinkTokenInterface(address(linkToken)),
            IRoleManager(address(0xC3)) // unused by xReceive
        );

        // ---- L2 deposit (real) ----
        deposit_ = xRenzoDeposit(payable(_proxify(address(new xRenzoDeposit()))));
        deposit_.initialize(
            1e18, // initial ezETH price = 1.0
            IERC20(address(xezETH)),
            IERC20(address(wethL2)),
            IERC20(address(nextWETH)),
            IConnext(address(connext)),
            bytes32("swap"),
            address(0xD1), // receiver (non-zero) -> getMintRate uses lastPrice
            1, // bridge destination domain
            address(bridge), // bridge target
            IRenzoOracleL2(address(0)) // no L2 oracle
        );

        // ---- XERC20 bridge limits: deposit mints, bridge burns ----
        xezETH.setLimits(address(deposit_), 1e27, 1e27);
        xezETH.setLimits(address(bridge), 1e27, 1e27);

        // ---- allow this contract to act as the sweeper ----
        deposit_.setAllowedBridgeSweeper(address(this), true);
    }

    function test_xezETHSupplyDesyncsFromEzETHBacking() public {
        // === STEP 1 (L2): Alice deposits 1 ETH worth of WETH at ezETH price 1.0 ===
        vm.deal(ALICE, 1 ether);
        vm.startPrank(ALICE);
        wethL2.deposit{value: 1 ether}();
        wethL2.approve(address(deposit_), type(uint256).max);
        uint256 minted = deposit_.deposit(1 ether, 0, type(uint256).max);
        vm.stopPrank();

        // Alice holds the L2 receipt (xezETH), minted at the OLD (1.0) valuation.
        uint256 circulating = xezETH.balanceOf(ALICE);
        assertEq(circulating, minted, "alice holds all minted xezETH");
        // 1 ETH - 5bps deposit fee, - 5bps router fee, /price 1.0 = 0.99900025 xezETH.
        assertEq(circulating, 999000250000000000, "L2 minted xezETH amount");

        // === STEP 2: ezETH valuation rises to 2.0 before the batch settles on L1 ===
        // (protocol rewards accrue into TVL; TVL 100 -> 200, supply 100 => price 2.0)
        restakeManager.accrueRewards(100 ether);

        // === STEP 3 (L1): sweep -> xcall -> xReceive deposits at the NEW valuation ===
        deposit_.sweep();

        // ezETH minted/locked by the bridge, at the ~2.0 valuation, for the same batch.
        uint256 backing = ezETH.balanceOf(address(lockbox));
        assertGt(backing, 0, "some ezETH backing was created");

        // === HARM: more xezETH in circulation than ezETH backing it 1:1 ===
        assertLt(backing, circulating, "backing is short of circulating supply");
        // Price doubled => backing is ~half the circulating receipt supply.
        assertApproxEqRel(backing, circulating / 2, 0.01e18, "backing ~= half circulating");

        uint256 shortfall = circulating - backing;
        emit log_named_decimal_uint("circulating xezETH", circulating, 18);
        emit log_named_decimal_uint("ezETH backing     ", backing, 18);
        emit log_named_decimal_uint("unbacked xezETH   ", shortfall, 18);
        assertApproxEqRel(shortfall, circulating / 2, 0.01e18, "~half the supply is unbacked");

        // === HARM proof: Alice cannot redeem her full receipt balance 1:1 ===
        vm.startPrank(ALICE);
        xezETH.approve(address(lockbox), type(uint256).max);
        vm.expectRevert(); // lockbox holds only `backing` ezETH < circulating
        lockbox.withdraw(circulating);

        // She can only redeem the backed portion; the rest is permanently stranded.
        lockbox.withdraw(backing);
        assertEq(ezETH.balanceOf(ALICE), backing, "alice redeemed only the backed half");

        uint256 stranded = xezETH.balanceOf(ALICE);
        assertEq(stranded, circulating - backing, "remaining xezETH is unredeemable");
        assertGt(stranded, 0, "stranded xezETH exists");

        // Any further redemption reverts: the lockbox is empty of ezETH.
        assertEq(ezETH.balanceOf(address(lockbox)), 0, "lockbox drained of ezETH");
        vm.expectRevert();
        lockbox.withdraw(1);
        vm.stopPrank();
    }

    receive() external payable {}
}
