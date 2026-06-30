// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;


import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "./OrderMixin.sol";
import "./OrderRFQMixin.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "./libraries/UniversalERC20.sol";

/// @title openocean Limit Order Protocol v2
contract LimitOrderProtocol is
EIP712Upgradeable,
OrderMixin,
OrderRFQMixin, KeeperCompatibleInterface
{
    using UniversalERC20 for IERC20Upgradeable;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;

    event Swap(bytes32 indexed orderHash, address indexed from, address[] path, uint[] amounts, address fee,
        bytes swapExtraData);

    function initialize() public initializer {
        __EIP712_init("openocean Limit Order Protocol", "2");
        __Ownable_init();
    }
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    struct Param {
        bool isETH;
        bool success;
        uint256 returnAmount;
        uint256 delta;
        address to;
    }

    struct SwapData {
        address from;
        address[] path;
        uint[] amounts;
        address fee;
        bytes swapExtraData;
        bytes32 orderHash;
    } 
    error SwapFailed(bytes32 orderHash);

    function batchSwap(SwapData[] calldata swaps) public payable onlyOperator {
        for (uint i = 0; i < swaps.length; i++) {
          
            swap(
                swaps[i].from,
                swaps[i].path,
                swaps[i].amounts,
                swaps[i].fee,
                swaps[i].swapExtraData,
                swaps[i].orderHash
            );
        }
    }

    function swap(address from, address[] calldata path, uint[] calldata amounts, address fee,
        bytes calldata swapExtraData, bytes32 orderHash) public payable onlyOperator {
        require(path.length == 2 && amounts.length == 2, "invalid args");
        address ooSwap = getOOswap();
        require(ooSwap != address(0), "ooswap is zero");
        Param memory vars;
        vars.isETH = IERC20Upgradeable(path[0]).isETH();
        if (!vars.isETH) {
            try this.transferTokens(path[0], from, address(this), amounts[0]) {
                IERC20Upgradeable(path[0]).safeIncreaseAllowance(ooSwap, amounts[0]);
            } catch {
                revert SwapFailed(orderHash);
            }
            
        }
        uint256 balBefore = IERC20Upgradeable(path[1]).balanceOf(address(this));
        (vars.success,) = ooSwap.call{value : msg.value}(swapExtraData);
        if (!vars.success) {
            revert SwapFailed(orderHash);
        } 
        //require(vars.success, "swap failed");
        uint256 balAfter = IERC20Upgradeable(path[1]).balanceOf(address(this));
        if (!vars.isETH) {
            IERC20Upgradeable(path[0]).safeApprove(ooSwap, 0);
        }
        vars.returnAmount = balAfter - balBefore;
        if (vars.returnAmount < amounts[1]) {
            revert SwapFailed(orderHash);
        }
        //require(vars.returnAmount >= amounts[1], "returnAmount is too low");
        IERC20Upgradeable(path[1]).universalTransfer(from, amounts[1]);
        vars.delta = vars.returnAmount - amounts[1];
        vars.to = fee == address(0) ? owner() : fee;
        if (vars.delta > 0) {
            IERC20Upgradeable(path[1]).universalTransfer(vars.to, vars.delta);
        }
        emit Swap(orderHash, from, path, amounts, vars.to, swapExtraData);
    }

    function transferTokens(address token, address from, address to, uint256 amount) external {
        IERC20Upgradeable(token).safeTransferFrom(from, to, amount);
    }

    function checkUpkeep(bytes calldata) override external pure returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = false; 
        performData = new bytes(0);
    }

    function performUpkeep(bytes calldata performData) override external {
    }

    function validSignature(address from, bytes32 orderHash, bytes calldata signature) public view returns(bool) {
        return SignatureCheckerUpgradeable.isValidSignatureNow(from, orderHash, signature);
    }
}
