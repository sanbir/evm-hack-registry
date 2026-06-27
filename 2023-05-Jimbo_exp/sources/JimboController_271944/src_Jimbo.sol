// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// import {ILBRouter} from "joe-v2/interfaces/ILBRouter.sol";
import {ILBPair} from "joe-v2/interfaces/ILBPair.sol";
import {IUniswapV2Pair} from "uni-v2/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "uni-v3/interfaces/IUniswapV3Pool.sol";

import {JimboController} from "./JimboController.sol";

contract Jimbo is ERC20 {
    error Unauthorized();
    error VaultAlreadySet();

    JimboController public immutable controller;

    address public immutable jrs; // Jimmy Revenue Service (JRS) address
    address public vault; // uJimbo vault address

    // in 10ths of a percent because of the .5% JRS_FEE
    uint256 public constant BUY_BURN_FEE = 40;
    uint256 public constant SELL_BURN_FEE = 10;
    uint256 public constant SELL_STAKER_FEE = 30;
    uint256 public constant JRS_FEE = 5;

    uint256 internal constant PRECISION = 1e18;
    uint256 public constant INITIAL_TOTAL_SUPPLY = 69_420_001 * 1e18;

    bool public isRebalancing;

    constructor(address jrs_) ERC20("TURBOJIMBO", "JIMBO", 18) {
        // Mint initial supply to controller
        controller = JimboController(msg.sender);
        jrs = jrs_;
        _mint(msg.sender, INITIAL_TOTAL_SUPPLY);
    }

    function setVault(address vault_) external {
        if (msg.sender != address(controller)) revert Unauthorized();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
    }

    function setIsRebalancing(bool isRebalancing_) external {
        if (msg.sender != address(controller)) revert Unauthorized();
        isRebalancing = isRebalancing_;
    }

    /// -----------------------------------------------------------------------
    /// OVERRIDES
    /// -----------------------------------------------------------------------
    function transfer(
        address to_,
        uint256 amount_
    ) public virtual override returns (bool) {
        balanceOf[msg.sender] -= amount_;

        uint256 _amount = _chargeTax(msg.sender, to_, amount_);

        unchecked {
            balanceOf[to_] += _amount;
        }

        emit Transfer(msg.sender, to_, _amount);

        return true;
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 amount_
    ) public virtual override returns (bool) {

        // Saves gas for limited approvals.
        uint256 allowed = allowance[from_][msg.sender];

        if (allowed != type(uint256).max)
            allowance[from_][msg.sender] = allowed - amount_;

        balanceOf[from_] -= amount_;

        uint256 _amount = _chargeTax(msg.sender, to_, amount_);

        unchecked {
            balanceOf[to_] += _amount;
        }

        emit Transfer(from_, to_, _amount);

        return true;
    }

    /// -----------------------------------------------------------------------
    /// TAX LOGIC
    /// -----------------------------------------------------------------------

    function _chargeTax(
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 _amount) {
        _amount = amount;

        if (!isRebalancing) {
            uint256 sendToVault;

            // BUYS: 4% burn / 0% stakers / .5% JRS)
            // SELLS: 1% burn / 3% stakers / .5% JRS)

            // Buy tax
            if (_isJoePool(from) || _isUniV3Pool(from) || _isUniV2Pair(from)) {
                uint256 jrsFee = _calculateFee(_amount, JRS_FEE);
                uint256 burn = _calculateFee(_amount, BUY_BURN_FEE);

                balanceOf[jrs] += jrsFee;
                emit Transfer(from, jrs, jrsFee);

                unchecked {
                    totalSupply -= burn;
                }
                emit Transfer(from, address(0), burn);

                _amount -= (jrsFee + burn);
            }

            // Sell tax
            if (_isJoePool(to) || _isUniV3Pool(to) || _isUniV2Pair(to)) {
                uint256 jrsFee = _calculateFee(_amount, JRS_FEE);
                uint256 burn = _calculateFee(_amount, SELL_BURN_FEE);
                sendToVault = _calculateFee(_amount, SELL_STAKER_FEE);

                balanceOf[jrs] += jrsFee;
                emit Transfer(from, jrs, jrsFee);

                balanceOf[vault] += sendToVault;
                emit Transfer(from, vault, sendToVault);

                unchecked {
                    totalSupply -= burn;
                }
                emit Transfer(from, address(0), burn);

                _amount -= (jrsFee + sendToVault + burn);

                // Call relevant rebalance functions on controller.
                // These will return early if not able to be called.
                controller.recycle();
                controller.reset();
            }
        }
    }

    /// -----------------------------------------------------------------------
    /// MORE HELPERS AND VIEW FUNCS
    /// -----------------------------------------------------------------------

    function _calculateFee(
        uint256 amount,
        uint256 pct
    ) internal pure returns (uint256) {
        uint256 feePercentage = (PRECISION * pct) / 1000; // x pct
        return (amount * feePercentage) / PRECISION;
    }

    function _isJoePool(address target) internal view returns (bool) {
        if (target.code.length == 0) return false;

        ILBPair pool = ILBPair(target);

        try pool.getTokenX() {} catch (bytes memory) {
            return false;
        }

        try pool.getTokenY() {} catch (bytes memory) {
            return false;
        }

        try pool.getBinStep() {} catch (bytes memory) {
            return false;
        }

        return true;
    }

    function _isUniV3Pool(address target) internal view returns (bool) {
        if (target.code.length == 0) return false;

        IUniswapV3Pool pool = IUniswapV3Pool(target);

        try pool.token0() {} catch (bytes memory) {
            return false;
        }

        try pool.token1() {} catch (bytes memory) {
            return false;
        }

        try pool.fee() {} catch (bytes memory) {
            return false;
        }

        return true;
    }

    function _isUniV2Pair(address target) internal view returns (bool) {
        if (target.code.length == 0) return false;

        IUniswapV2Pair uniPair = IUniswapV2Pair(target);

        try uniPair.token0() {} catch (bytes memory) {
            return false;
        }

        try uniPair.token1() {} catch (bytes memory) {
            return false;
        }

        try uniPair.kLast() {} catch (bytes memory) {
            return false;
        }

        return true;
    }
}
