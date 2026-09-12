// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../gdc/GDCToken.sol";
import "../shared/libraries/UniswapOperations.sol";

/**
 * @title GDCTokenHarness
 * @notice 测试/E2E 专用：继承 GDCToken 并暴露 owner 测试辅助函数（生产部署不使用）
 */
contract GDCTokenHarness is GDCToken {
    constructor(
        address _router,
        address _wbnb,
        address _baseToken,
        address _distributor,
        address[] memory _extraTaxExempt
    ) GDCToken(_router, _wbnb, _baseToken, _distributor, _extraTaxExempt) {}

    /// @notice 测试用：主动触发通缩并按批执行分红分配，可重复调用
    function testTriggerDeflationAndDistribute(uint256 rounds) external onlyOwner {
        require(!swapping, "swapping");
        swapping = true;

        if (!_hasActiveDistribution() && rounds > 0 && !deflationStopped) {
            _executeDeflation(rounds);
        }

        if (_hasActiveDistribution()) {
            _executeDistribute();
        }

        swapping = false;
    }

    /// @notice 测试用：直接设置通缩账本，便于跳到阶段一末/阶段二/阶段三
    function testSetDeflationLedger(
        uint256 base,
        bool endStage1,
        uint256 stage2Remain,
        bool stopped
    ) external onlyOwner {
        deflationBase = base;
        stage1Ended = endStage1;
        stage2Remaining = stage2Remain;
        deflationStopped = stopped;
    }

    /// @notice 测试用：设置卖出基数相关状态
    function testSetDeflationSellState(
        address user,
        uint256 base,
        uint256 cycleStart,
        uint256 cumulative
    ) external onlyOwner {
        deflationSellBase[user] = base;
        deflationSellCycleStartCount[user] = cycleStart;
        cumulativeSellAmount[user] = cumulative;
    }

    /// @notice 测试用：提取合约内残留 native BNB 至指定地址（通常 deployer）
    function testWithdrawBNB(address payable to) external onlyOwner {
        if (to == address(0)) revert InvalidBeneficiary();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = to.call{value: bal}("");
        require(ok, "BNB transfer failed");
    }

    /// @notice 测试用：将合约自身持有的 GDC 转给指定地址，便于链下卖出回收
    function testTransferContractGDC(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidBeneficiary();
        _update(address(this), to, amount);
    }

    /// @notice 测试用：暴露 optimalSwapIn 纯函数
    function testOptimalSwapIn(uint256 reserveIn, uint256 amountIn, uint256 feeBps) external pure returns (uint256) {
        return UniswapOperations.optimalSwapIn(reserveIn, amountIn, feeBps);
    }
}
