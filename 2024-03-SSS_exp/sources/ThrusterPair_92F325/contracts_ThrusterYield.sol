// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.5.16;

import "interfaces/IBlast.sol";
import "interfaces/IThrusterYield.sol";
import "interfaces/IERC20Rebasing.sol";

contract ThrusterYield is IThrusterYield {
    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    IERC20Rebasing public constant USDB = IERC20Rebasing(0x4300000000000000000000000000000000000003);
    IERC20Rebasing public constant WETHB = IERC20Rebasing(0x4300000000000000000000000000000000000004);
    address public manager;

    event ClaimYieldAll(
        address indexed recipient, uint256 amountWETH, uint256 amountUSDB, uint256 amountGas
    );
    event ClaimGas(address indexed recipient, uint256 amount);

    modifier onlyManager() {
        require(msg.sender == manager, "FORBIDDEN");
        _;
    }

    constructor(address _manager) public {
        BLAST.configureClaimableGas();
        USDB.configure(IERC20Rebasing.YieldMode.CLAIMABLE);
        WETHB.configure(IERC20Rebasing.YieldMode.CLAIMABLE);
        manager = _manager;
    }

    function claimYieldAll(address _recipient, uint256 _amountWETH, uint256 _amountUSDB)
        external
        onlyManager
        returns (uint256 amountWETH, uint256 amountUSDB, uint256 amountGas)
    {
        amountWETH = IERC20Rebasing(WETHB).claim(_recipient, _amountWETH);
        amountUSDB = IERC20Rebasing(USDB).claim(_recipient, _amountUSDB);
        amountGas = IBlast(BLAST).claimMaxGas(address(this), _recipient);
        emit ClaimYieldAll(_recipient, amountWETH, amountUSDB, amountGas);
    }

    function claimGas(address _recipient, uint256 _minClaimRateBips) external onlyManager returns (uint256 amount) {
        if (_minClaimRateBips == 0) {
            amount = BLAST.claimMaxGas(address(this), _recipient);
        } else {
            amount = BLAST.claimGasAtMinClaimRate(address(this), _recipient, _minClaimRateBips);
        }
        emit ClaimGas(_recipient, amount);
    }

    function setManager(address _manager) external onlyManager {
        manager = _manager;
    }
}
