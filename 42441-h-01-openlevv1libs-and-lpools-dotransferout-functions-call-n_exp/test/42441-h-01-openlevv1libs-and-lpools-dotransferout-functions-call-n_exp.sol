// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import {LPool} from "../src/poc/liquidity/LPool.sol";
import {LPoolDelegator} from "../src/poc/liquidity/LPoolDelegator.sol";
import {WETH} from "../src/poc/test/WETH.sol";

/// @dev Minimal external permission gate. In production this is OpenLeverage's
/// ControllerV1, which merely checks pause flags and updates reward accounting
/// for mint/redeem. It is NOT where the bug lives — the vulnerable code is
/// entirely inside the REAL LPool.doTransferOut below. LPool casts the
/// controller address to ControllerInterface and calls these five selectors;
/// permitting them is the faithful "the protocol lets the user mint/redeem".
contract MockController {
    function mintAllowed(address, uint) external {}
    function transferAllowed(address, address, uint) external {}
    function redeemAllowed(address, uint) external {}
    function borrowAllowed(address, address, uint) external {}
    function repayBorrowAllowed(address, address, uint, bool) external {}
}

interface ILPool {
    function mintEth() external payable;
    function redeem(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

/// @dev A contract lender whose ETH-receiving path fits Solidity's 2300-gas
/// `transfer` stipend (empty receive). This is the control case: it can redeem.
contract CheapLender {
    function deposit(address pool, uint256 amount) external {
        ILPool(pool).mintEth{value: amount}();
    }

    function redeemAll(address pool) external {
        ILPool(pool).redeem(ILPool(pool).balanceOf(address(this)));
    }

    receive() external payable {}
}

/// @dev A perfectly ordinary contract lender (multisig, vault, router, another
/// protocol) whose receive path does a single SSTORE — ~20k gas, far above the
/// 2300 `transfer` stipend. This is the real class of recipient that the
/// audited LPool.doTransferOut permanently locks out of its own funds.
contract ContractLender {
    uint256 public received;

    function deposit(address pool, uint256 amount) external {
        ILPool(pool).mintEth{value: amount}();
    }

    function tryRedeemAll(address pool) external returns (bool ok) {
        uint256 bal = ILPool(pool).balanceOf(address(this));
        (ok, ) = pool.call(abi.encodeWithSelector(ILPool.redeem.selector, bal));
    }

    receive() external payable {
        received += msg.value; // > 2300 gas: cannot run inside transfer's stipend
    }
}

contract PoC_42441_OpenLevTransferOut is Test {
    WETH internal weth;
    MockController internal controller;
    LPool internal impl;
    address internal pool; // the LPoolDelegator proxy (address(this) inside LPool)
    CheapLender internal cheap;
    ContractLender internal hungry;

    function setUp() public {
        weth = new WETH();
        controller = new MockController();
        impl = new LPool();

        // Real Compound-style deploy: delegator proxy sets admin, delegatecalls
        // LPool.initialize, then flips admin/implementation.
        LPoolDelegator delegator = new LPoolDelegator();
        delegator.initialize(
            address(weth), // underlying_
            true, // isWethPool_  -> the vulnerable native-transfer branch
            address(controller), // controller_
            0, // baseRatePerYear
            0, // multiplierPerYear
            0, // jumpMultiplierPerYear
            0, // kink_
            1e18, // initialExchangeRateMantissa_ (1:1)
            "OpenLeverage ETH", // name_
            "lETH", // symbol_
            18, // decimals_
            payable(address(this)), // admin_
            address(impl) // implementation_
        );
        pool = address(delegator);

        cheap = new CheapLender();
        hungry = new ContractLender();

        vm.deal(address(cheap), 1 ether);
        vm.deal(address(hungry), 1 ether);
    }

    function testDoTransferOutFreezesContractLenderFunds() public {
        // Two contract lenders each supply 1 ETH into the WETH money market.
        cheap.deposit(pool, 1 ether);
        hungry.deposit(pool, 1 ether);

        assertEq(weth.balanceOf(pool), 2 ether, "pool holds both lenders' 2 ETH");
        assertEq(ILPool(pool).balanceOf(address(cheap)), 1e18, "cheap minted 1e18 lTokens");
        assertEq(ILPool(pool).balanceOf(address(hungry)), 1e18, "hungry minted 1e18 lTokens");

        // Control: a lender whose receive fits the 2300-gas stipend redeems fine.
        cheap.redeemAll(pool);
        assertEq(address(cheap).balance, 1 ether, "cheap lender withdrew its full 1 ETH");
        assertEq(weth.balanceOf(pool), 1 ether, "pool now backs only hungry's deposit");

        // Harm: an ordinary contract lender whose receive needs > 2300 gas has its
        // redeem() reverted by LPool.doTransferOut's `to.transfer(amount)`.
        bool ok = hungry.tryRedeemAll(pool);
        assertTrue(!ok, "redeem must revert for a contract lender needing > 2300 gas");

        // Concrete, permanent loss: 1 ETH is frozen. The lender received nothing,
        // still holds unredeemable lTokens, and the underlying stays trapped.
        assertEq(address(hungry).balance, 0, "hungry lender received nothing");
        assertEq(hungry.received(), 0, "hungry lender's receive never executed");
        assertEq(ILPool(pool).balanceOf(address(hungry)), 1e18, "hungry still holds unredeemable lTokens");
        assertEq(weth.balanceOf(pool), 1 ether, "hungry's 1 ETH is permanently frozen in the pool");
    }
}
