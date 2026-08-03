// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IAssetRegistry.sol";
import "../interfaces/IBackingManager.sol";
import "../interfaces/IBasketHandler.sol";
import "../interfaces/IStRSR.sol";

/// @dev Minimal REAL ERC20 for RSR. RSR is an opaque token the StRSR contract treats as a
///      plain ERC20; it is not part of the vulnerable era-reset logic.
contract MiniRSR is IERC20Metadata {
    string public name = "Reserve Rights";
    string public symbol = "RSR";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        require(balanceOf[f] >= amt, "bal");
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal Main. Main is pure infrastructure (component registry + access control),
///      NOT part of the vulnerable StRSR era-reset logic. It only reports the RSR token,
///      the backingManager (the only address allowed to seize), and unfrozen/unpaused state.
contract PoCMain32 {
    IERC20 internal _rsr;
    address internal _backingManager;

    constructor(IERC20 rsr_, address backingManager_) {
        _rsr = rsr_;
        _backingManager = backingManager_;
    }

    function rsr() external view returns (IERC20) {
        return _rsr;
    }

    function backingManager() external view returns (IBackingManager) {
        return IBackingManager(_backingManager);
    }

    function assetRegistry() external pure returns (IAssetRegistry) {
        return IAssetRegistry(address(0));
    }

    function basketHandler() external pure returns (IBasketHandler) {
        return IBasketHandler(address(0));
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
    }

    function frozen() external pure returns (bool) {
        return false;
    }

    function tradingPausedOrFrozen() external pure returns (bool) {
        return false;
    }

    function issuancePausedOrFrozen() external pure returns (bool) {
        return false;
    }
}

interface IStakeable {
    function stake(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @dev A genuine third-party staker (the victim). Holds RSR, approves StRSR, and stakes.
///      Its stRSR balance is the "significant value" the era-reset wipes out.
contract Staker {
    function approveAndStake(IERC20 rsr, address stRSR, uint256 amount) external {
        rsr.approve(stRSR, type(uint256).max);
        IStakeable(stRSR).stake(amount);
    }
}
