// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {xRenzoDeposit} from "../src/selected/Bridge/L2/xRenzoDeposit.sol";
import {IConnext} from "../src/selected/Bridge/Connext/core/IConnext.sol";
import {IRenzoOracleL2} from "../src/selected/Bridge/L2/Oracle/IRenzoOracleL2.sol";

contract MockAsset is ERC20 {
    constructor(string memory name_) ERC20(name_, name_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockConnext {
    function swapExact(bytes32, uint256 amountIn, address, address, uint256, uint256) external pure returns (uint256) {
        return amountIn;
    }
}

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
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract PoC_33493 is Test {
    MockAsset private xezETH;
    MockAsset private depositToken;
    MockAsset private collateralToken;
    xRenzoDeposit private deposit;
    address private user = address(0xBEEF);

    function setUp() public {
        xezETH = new MockAsset("xezETH");
        depositToken = new MockAsset("WETH");
        collateralToken = new MockAsset("nextWETH");
        MockConnext connext = new MockConnext();
        xRenzoDeposit implementation = new xRenzoDeposit();
        DelegateProxy proxy = new DelegateProxy(address(implementation));
        deposit = xRenzoDeposit(payable(address(proxy)));
        deposit.initialize(
            1e18,
            xezETH,
            depositToken,
            collateralToken,
            IConnext(address(connext)),
            bytes32("swap"),
            address(1),
            1,
            address(2),
            IRenzoOracleL2(address(0))
        );

        depositToken.mint(user, 1e18);
        vm.prank(user);
        depositToken.approve(address(deposit), type(uint256).max);
    }

    function test_l2MintAtOldPriceLeavesSupplyUnderBackedAfterL1PriceRises() public {
        vm.warp(100);
        vm.prank(user);
        uint256 minted = deposit.deposit(1e18, 0, type(uint256).max);

        // Follow the real owner price-feed path, respecting the 10% step limit in _updatePrice.
        uint256[8] memory prices = [
            uint256(1.1e18),
            uint256(1.21e18),
            uint256(1.331e18),
            uint256(1.4641e18),
            uint256(1.61051e18),
            uint256(1.771561e18),
            uint256(1.9487171e18),
            uint256(2.14358881e18)
        ];
        for (uint256 i; i < prices.length; ++i) {
            vm.warp(block.timestamp + 1);
            deposit.updatePriceByOwner(prices[i]);
        }

        // L2 minted xezETH from the old valuation. At the new ~2x valuation, only half that
        // amount of ezETH is minted/locked by xRenzoBridge::xReceive for the same ETH batch.
        uint256 backingAtNewPrice = (minted * 1e18) / deposit.lastPrice();
        assertGt(minted, backingAtNewPrice * 2, "rounding should not erase the supply mismatch");
        assertEq(xezETH.balanceOf(user), minted);
    }
}
