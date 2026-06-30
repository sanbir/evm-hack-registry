// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {SafeMath} from './SafeMath.sol';
import {IUniswapV2Factory} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import {IUniswapV2Router02} from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import {IUniswapV2Factory} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import {ROUTER, FACTORY} from '../Const.sol';

library Helper {
    using SafeMath for uint256;

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        if (size == 0) {
            return false;
        }
        if (size != 23) {
            return true;
        }
        bytes memory code = new bytes(3);
        assembly {
            extcodecopy(account, add(code, 0x20), 0, 3)
        }
        return !(code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn * 9975;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountIn) {
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * 9975;
        amountIn = (numerator / denominator) + 1;
    }

    function getReserves(address target) public view returns (uint256, uint256) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature('getReserves()'));
        require(success && data.length > 0, 'Helper: getReserves');
        (uint112 reserve0, uint112 reserve1, ) = abi.decode(data, (uint112, uint112, uint32));
        return (uint256(reserve0), uint256(reserve1));
    }

    function getTotalSupply(address target) public view returns (uint256 totalSupply) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature('totalSupply()'));
        require(success && data.length > 0, 'Helper: totalSupply');
        (totalSupply) = abi.decode(data, (uint256));
    }

    function getFeeLP(address pair, uint256 virtualTotalSupply, uint256 reservesToken0, uint256 reservesThis) internal view returns (uint256 amount) {
        uint256 rootK = SafeMath.sqrt(reservesToken0.mul(reservesThis));
        uint256 rootKLast = SafeMath.sqrt(IUniswapV2Pair(pair).kLast());
        if (rootK > rootKLast) {
            uint256 numerator = virtualTotalSupply.mul(rootK.sub(rootKLast)).mul(8);
            uint256 denominator = rootK.mul(17).add(rootKLast.mul(8));
            amount = numerator / denominator;
        }
    }

    function isAddLiquidity(IERC20 token0, uint256 amount, address pair) internal view returns (uint256 lpAmount, uint256 deltaUSDT) {
        if (msg.sender == ROUTER) {
            (uint256 reservesToken0, uint256 reservesThis) = getReserves(pair);
            uint256 balanceToken0 = token0.balanceOf(pair);
            if (balanceToken0 > reservesToken0) {
                uint256 virtualTotalSupply = getTotalSupply(pair);
                if (virtualTotalSupply == 0) return (0, 0);
                deltaUSDT = balanceToken0 - reservesToken0;
                if (IUniswapV2Factory(FACTORY).feeTo() != address(0)) virtualTotalSupply = virtualTotalSupply.add(getFeeLP(pair, virtualTotalSupply, reservesToken0, reservesThis));
                uint256 lpFromToken0 = deltaUSDT.mul(virtualTotalSupply) / reservesToken0;
                uint256 lpFromThis = amount.mul(virtualTotalSupply) / reservesThis;
                uint256 minLP = lpFromThis < lpFromToken0 ? lpFromThis : lpFromToken0;
                uint256 maxLP = lpFromThis > lpFromToken0 ? lpFromThis : lpFromToken0;
                if (maxLP <= (minLP * 100001) / 100000) {
                    lpAmount = minLP;
                }
            }
        }
    }

    function isRemoveLiquidity(IERC20 token0, uint256 amount, address pair) internal view returns (uint256 lpAmount) {
        (uint256 reservesToken0, uint256 reservesThis) = getReserves(pair);
        uint256 balanceToken0 = token0.balanceOf(pair);
        if (reservesToken0 > balanceToken0) {
            uint256 virtualTotalSupply = getTotalSupply(pair);
            uint256 lpFromToken0 = (reservesToken0 - balanceToken0).mul(virtualTotalSupply) / balanceToken0;
            uint256 lpFromThis = amount.mul(virtualTotalSupply) / reservesThis.sub(amount);
            uint256 minLP = lpFromThis < lpFromToken0 ? lpFromThis : lpFromToken0;
            uint256 maxLP = lpFromThis > lpFromToken0 ? lpFromThis : lpFromToken0;
            if (maxLP <= (minLP * 100001) / 100000) {
                lpAmount = maxLP;
            }
        }
    }

    function add(uint256 base, int256 delta) internal pure returns (uint256) {
        return delta < 0 && -delta > int256(base) ? 0 : uint256(int256(base) + delta);
    }
}
