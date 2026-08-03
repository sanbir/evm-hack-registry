// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/reserve/target/p1/AssetRegistry.sol";
import "../src/reserve/target/p1/BasketHandler.sol";
import "../src/reserve/target/p1/mixins/BasketLib.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "../src/reserve/target/interfaces/IAsset.sol";
import "../src/reserve/target/poc/PoCEnv.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Real-source reproduction of Reserve H-01 (Code4rena 2023-06, commit c4ec2473).
///         Deploys the REAL AssetRegistryP1 and the REAL (vulnerable) BasketHandlerP1 and
///         drives them through the real governance path: register 3 collateral, record a
///         3-asset historical basket, switch the prime basket to 2 assets, then unregister
///         one of the old assets. AssetRegistry.size() (a REAL EnumerableSet) drops to 2
///         while basketHistory[1] still holds 3 erc20s. quoteCustomRedemption then sizes
///         erc20sAll from registry.size()=2 and writes index 2 -> index-out-of-bounds.
contract PoC_27331 is Test {
    AssetRegistryP1 internal assetRegistry;
    BasketHandlerP1 internal basketHandler;
    PoCMain internal main;
    PoCBackingManager internal backingManager;

    MiniERC20 internal usdc;
    MiniERC20 internal usdt;
    MiniERC20 internal dai;
    MiniCollateral internal collUSDC;
    MiniCollateral internal collUSDT;
    MiniCollateral internal collDAI;

    bytes32 internal constant USD = bytes32("USD");

    // Must match foundry.toml `libraries` link for BasketLibP1.
    address internal constant BASKET_LIB = 0x8a6A5771513Da286B191417a57BAeb151F5D3320;

    function setUp() public {
        // BasketHandlerP1 is linked to BasketLibP1 at a fixed address; place its runtime
        // code there (the playground exploit CREATE2-self-deploys the same code).
        vm.etch(BASKET_LIB, type(BasketLibP1).runtimeCode);

        main = new PoCMain();
        backingManager = new PoCBackingManager();

        usdc = new MiniERC20("USD Coin", "USDC", 6);
        usdt = new MiniERC20("Tether", "USDT", 6);
        dai = new MiniERC20("Dai", "DAI", 18);
        collUSDC = new MiniCollateral(usdc, USD);
        collUSDT = new MiniCollateral(usdt, USD);
        collDAI = new MiniCollateral(dai, USD);

        // Deploy the REAL upgradeable components behind proxies with EMPTY init data,
        // then wire Main and call init() manually (breaks the component init cycle the
        // production Deployer resolves the same way).
        AssetRegistryP1 arImpl = new AssetRegistryP1();
        ERC1967Proxy arProxy = new ERC1967Proxy(address(arImpl), "");
        assetRegistry = AssetRegistryP1(address(arProxy));

        BasketHandlerP1 bhImpl = new BasketHandlerP1();
        ERC1967Proxy bhProxy = new ERC1967Proxy(address(bhImpl), "");
        basketHandler = BasketHandlerP1(address(bhProxy));

        main.setComponents(
            IAssetRegistry(address(assetRegistry)),
            IBackingManager(address(backingManager)),
            IBasketHandler(address(basketHandler)),
            IERC20(address(0xDEAD01)), // rsr sentinel (must differ from basket erc20s)
            IRToken(address(0xDEAD02)), // rToken sentinel
            IStRSR(address(0xDEAD03)) // stRSR sentinel
        );

        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(collUSDC));
        assets[1] = IAsset(address(collUSDT));
        assets[2] = IAsset(address(collDAI));
        assetRegistry.init(IMain(address(main)), assets);

        basketHandler.init(IMain(address(main)), 60);
    }

    function _quote() internal view returns (address[] memory erc20s, uint256[] memory qtys) {
        uint48[] memory nonces = new uint48[](1);
        nonces[0] = 1; // the historical 3-asset basket
        uint192[] memory portions = new uint192[](1);
        portions[0] = 1e18;
        return basketHandler.quoteCustomRedemption(nonces, portions, 1e18);
    }

    function test_customRedemption_bricked_after_old_asset_unregistered() public {
        // === Governance records the initial 3-asset prime basket (0.9 USDC, 0.05 USDT, 0.05 DAI) ===
        IERC20[] memory e3 = new IERC20[](3);
        e3[0] = IERC20(address(usdc));
        e3[1] = IERC20(address(usdt));
        e3[2] = IERC20(address(dai));
        uint192[] memory w3 = new uint192[](3);
        w3[0] = 0.9e18;
        w3[1] = 0.05e18;
        w3[2] = 0.05e18;
        basketHandler.setPrimeBasket(e3, w3);
        basketHandler.refreshBasket(); // nonce 1 = {USDC, USDT, DAI}
        assertEq(basketHandler.nonce(), 1, "historical basket nonce");
        assertEq(assetRegistry.size(), 3, "registry has 3 assets");

        // Redemption of the historical basket WORKS while all three assets are registered.
        (address[] memory before, ) = _quote();
        assertEq(before.length, 3, "custom redemption returns the 3 backing assets");

        // === Governance switches to a 2-asset basket (0.9 DAI, 0.1 USDC) and unregisters USDT ===
        IERC20[] memory e2 = new IERC20[](2);
        e2[0] = IERC20(address(dai));
        e2[1] = IERC20(address(usdc));
        uint192[] memory w2 = new uint192[](2);
        w2[0] = 0.9e18;
        w2[1] = 0.1e18;
        basketHandler.setPrimeBasket(e2, w2);
        basketHandler.refreshBasket(); // nonce 2 = {DAI, USDC}

        assetRegistry.unregister(IAsset(address(collUSDT))); // REAL size 3 -> 2
        assertEq(assetRegistry.size(), 2, "registry now has 2 assets, old basket still has 3");

        // === Harm: the SAME legitimate redemption request now reverts with index-out-of-bounds ===
        // quoteCustomRedemption sizes erc20sAll from registry.size()=2 but iterates the
        // 3-erc20 historical basket, writing erc20sAll[2] out of bounds -> Panic(0x32).
        vm.expectRevert(stdError.indexOOBError);
        _quote();
    }
}
