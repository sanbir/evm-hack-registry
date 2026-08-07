// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {YToken, YTokenFixed} from "../src/yieldfi/YToken.sol";
import {Manager} from "../src/yieldfi/Manager.sol";
import {Administrator} from "../src/yieldfi/Administrator.sol";
import {Constants} from "../src/yieldfi/Constants.sol";

/// @dev Minimal REAL ERC20 underlying (the sToken/asset). Not the finding target.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract PoC_55538_WrongOwnerToManagerRedeem is Test {
    MockUSDC internal usdc;
    Administrator internal admin;
    Manager internal manager;
    YToken internal ytoken;

    address internal victim = makeAddr("victim");
    address internal u1 = makeAddr("u1"); // third party acting on victim's behalf
    address internal receiver = makeAddr("receiver");

    uint256 internal constant VICTIM_SHARES = 100 ether;
    uint256 internal constant U1_SHARES = 50 ether;
    uint256 internal constant REDEEM = 50 ether;

    function setUp() public {
        usdc = new MockUSDC();
        admin = new Administrator(); // this test contract holds ADMIN_ROLE
        manager = new Manager();
        ytoken = new YToken(IERC20(address(usdc)), address(admin), address(manager));

        // Manager must hold MINTER_AND_REDEEMER to burn shares during execution.
        address[] memory who = new address[](1);
        who[0] = address(manager);
        admin.grantRoles(Constants.MINTER_AND_REDEEMER_ROLE, who);
    }

    function _deposit(address who, uint256 assets, YToken yt) internal {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(yt), assets);
        yt.deposit(assets, who);
        vm.stopPrank();
    }

    /// WORST CASE: the third-party caller ALSO holds shares. The delegated redeem
    /// burns the CALLER's shares instead of the owner's -> wrong account debited.
    function test_wrongUsersTokensBurned() public {
        _deposit(victim, VICTIM_SHARES, ytoken);
        _deposit(u1, U1_SHARES, ytoken);

        // victim authorises u1 to redeem 50 of victim's shares
        vm.prank(victim);
        ytoken.approve(u1, REDEEM);

        assertEq(ytoken.balanceOf(victim), VICTIM_SHARES);
        assertEq(ytoken.balanceOf(u1), U1_SHARES);

        // u1 redeems 50 shares ON BEHALF OF victim
        vm.prank(u1);
        ytoken.redeem(REDEEM, receiver, victim);

        // HARM: u1's OWN shares were burned; victim's shares are untouched even
        // though victim's allowance to u1 was consumed. The wrong account paid.
        assertEq(ytoken.balanceOf(u1), U1_SHARES - REDEEM, "caller's shares wrongly burned"); // 50 -> 0
        assertEq(ytoken.balanceOf(victim), VICTIM_SHARES, "victim's shares should NOT be intact under a correct redeem"); // still 100
        assertEq(ytoken.allowance(victim, u1), 0, "victim's allowance was spent for nothing");
    }

    /// CONTROL: the fixed YToken passes `owner`, so victim's shares are burned
    /// and u1's remain intact — proving the swap of msg.sender for owner is the bug.
    function test_control_fixedBurnsCorrectOwner() public {
        YTokenFixed yt = new YTokenFixed(IERC20(address(usdc)), address(admin), address(manager));

        _deposit(victim, VICTIM_SHARES, YToken(address(yt)));
        _deposit(u1, U1_SHARES, YToken(address(yt)));

        vm.prank(victim);
        yt.approve(u1, REDEEM);

        vm.prank(u1);
        yt.redeem(REDEEM, receiver, victim);

        assertEq(yt.balanceOf(victim), VICTIM_SHARES - REDEEM, "victim's shares must be burned under the fix"); // 100 -> 50
        assertEq(yt.balanceOf(u1), U1_SHARES, "u1's shares must be untouched under the fix"); // still 50
    }

    /// DoS CASE: the third-party caller holds NO shares. The delegated redeem
    /// reverts "!balance" (it tries to burn the caller's non-existent shares),
    /// permanently blocking third-party withdrawals — the exact failure the
    /// audit report's PoC observes.
    function test_thirdPartyWithdrawalReverts() public {
        _deposit(victim, VICTIM_SHARES, ytoken); // u1 has NO shares

        vm.prank(victim);
        ytoken.approve(u1, REDEEM);

        vm.prank(u1);
        vm.expectRevert(bytes("!balance"));
        ytoken.redeem(REDEEM, receiver, victim);

        // victim's shares remain locked; the withdrawal cannot be processed.
        assertEq(ytoken.balanceOf(victim), VICTIM_SHARES, "victim funds stuck");
    }
}
