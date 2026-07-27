// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/reserve/target/p1/BasketHandler.sol";
import "../src/reserve/target/interfaces/IAsset.sol";
import "../src/reserve/target/interfaces/IAssetRegistry.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockReserveToken is ERC20 {
    constructor(string memory name_) ERC20(name_, name_) {}
}

contract MockReserveCollateral {
    IERC20Metadata public immutable token;
    bytes32 public immutable targetNameValue;

    constructor(IERC20Metadata token_, bytes32 targetName_) {
        token = token_;
        targetNameValue = targetName_;
    }

    function erc20() external view returns (IERC20Metadata) { return token; }
    function erc20Decimals() external view returns (uint8) { return token.decimals(); }
    function isCollateral() external pure returns (bool) { return true; }
    function status() external pure returns (CollateralStatus) { return CollateralStatus.SOUND; }
    function refPerTok() external pure returns (uint192) { return 1e18; }
    function targetPerRef() external pure returns (uint192) { return 1e18; }
    function targetName() external view returns (bytes32) { return targetNameValue; }
    function refresh() external {}
    function price() external pure returns (uint192, uint192) { return (1e18, 1e18); }
    function bal(address) external pure returns (uint192) { return 0; }
    function maxTradeVolume() external pure returns (uint192) { return 1e30; }
    function lastSave() external pure returns (uint48) { return 0; }
    function savedPegPrice() external pure returns (uint192) { return 1e18; }
}

contract MockReserveRegistry {
    mapping(address => IAsset) internal assets;
    mapping(address => bool) internal registered;
    uint256 internal registrySize;

    function add(IERC20 token, IAsset asset) external {
        assets[address(token)] = asset;
        registered[address(token)] = true;
        registrySize++;
    }

    function unregister(IERC20 token) external {
        registered[address(token)] = false;
        registrySize--;
    }

    function refresh() external {}
    function size() external view returns (uint256) { return registrySize; }
    function isRegistered(IERC20 token) external view returns (bool) { return registered[address(token)]; }
    function toAsset(IERC20 token) external view returns (IAsset) {
        require(registered[address(token)], "erc20 unregistered");
        return assets[address(token)];
    }
    function toColl(IERC20 token) external view returns (ICollateral) {
        require(registered[address(token)], "erc20 unregistered");
        return ICollateral(address(assets[address(token)]));
    }
}

contract MockReserveMain {
    IAssetRegistry internal registry;

    constructor(IAssetRegistry registry_) { registry = registry_; }
    function assetRegistry() external view returns (IAssetRegistry) { return registry; }
    function backingManager() external pure returns (IBackingManager) { return IBackingManager(address(0)); }
    function rsr() external pure returns (IERC20) { return IERC20(address(0)); }
    function rToken() external pure returns (IRToken) { return IRToken(address(0)); }
    function stRSR() external pure returns (IStRSR) { return IStRSR(address(0)); }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function tradingPausedOrFrozen() external pure returns (bool) { return false; }
}

contract PoC_27331 is Test {
    BasketHandlerP1 internal handler;
    MockReserveRegistry internal registry;
    MockReserveToken internal token1;
    MockReserveToken internal token2;
    MockReserveToken internal token3;

    function setUp() public {
        registry = new MockReserveRegistry();
        token1 = new MockReserveToken("USDC");
        token2 = new MockReserveToken("USDT");
        token3 = new MockReserveToken("DAI");
        registry.add(token1, IAsset(address(new MockReserveCollateral(token1, bytes32("USD")))));
        registry.add(token2, IAsset(address(new MockReserveCollateral(token2, bytes32("USD")))));
        registry.add(token3, IAsset(address(new MockReserveCollateral(token3, bytes32("USD")))));

        MockReserveMain main = new MockReserveMain(IAssetRegistry(address(registry)));
        // BasketHandler is an upgradeable implementation whose constructor
        // locks the implementation initializer. Exercise the production
        // initialization path through an ERC1967 proxy.
        BasketHandlerP1 implementation = new BasketHandlerP1();
        bytes memory initData = abi.encodeCall(BasketHandlerP1.init, (IMain(address(main)), 60));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        handler = BasketHandlerP1(address(proxy));

        IERC20[] memory assets = new IERC20[](3);
        assets[0] = token1;
        assets[1] = token2;
        assets[2] = token3;
        uint192[] memory weights = new uint192[](3);
        weights[0] = 1e18;
        weights[1] = 1e18;
        weights[2] = 1e18;
        handler.setPrimeBasket(assets, weights);
        handler.refreshBasket();

        // Governance unregisters the third asset after the old basket is
        // recorded. The actual registry now has only two entries.
        registry.unregister(token3);
    }

    function test_old_three_asset_basket_exceeds_current_registry_array() public {
        uint48[] memory nonces = new uint48[](1);
        nonces[0] = 1;
        uint192[] memory portions = new uint192[](1);
        portions[0] = 1e18;

        // In the vulnerable BasketHandlerP1 at c4ec2473, erc20sAll is sized
        // from registry.size() (=2), then the three-token historical basket
        // writes index 2 before checking registration.
        vm.expectRevert();
        handler.quoteCustomRedemption(nonces, portions, 1e18);
    }
}
