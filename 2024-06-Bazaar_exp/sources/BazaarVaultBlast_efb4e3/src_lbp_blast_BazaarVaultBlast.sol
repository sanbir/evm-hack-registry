pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {ReentrancyGuard} from "openzeppelin-0.7/utils/ReentrancyGuard.sol";

import {IERC20} from "openzeppelin-0.7/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-0.7/token/ERC20/SafeERC20.sol";

import {SafeMath} from "openzeppelin-0.7/math/SafeMath.sol";

import {IWETH9 as IWETH} from "../../interfaces/IWETH9.sol";
import {IERC20Rebasing, YieldMode} from "../../interfaces/blast/IERC20Rebasing.sol";
import {IBlast} from "../../interfaces/blast/IBlast.sol";
import {IBlastPoints} from "../../interfaces/blast/IBlastPoints.sol";

import {BazaarVault} from "../BazaarVault.sol";
import {BazaarManager} from "../../BazaarManager.sol";

// @notice A sub-implementation of the Balancer `IVault` interface backing the
//         the Balancer Pools created from the BazaarLBPFactory. This solely enables
//         Join/Exit/Swap functionality.
contract BazaarVaultBlast is BazaarVault {
    using SafeMath for uint256;

    IBlast public immutable BLAST;

    BazaarManager public immutable manager;

    address public immutable weth;

    mapping(IERC20Rebasing => bool) public rebasingTokens;

    modifier onlyManager() {
        require(manager.owner() == msg.sender);
        _;
    }

    constructor(address _weth, BazaarManager _manager, address pointsOperator, IBlast _blast, IBlastPoints BLAST_POINTS) BazaarVault(_weth) {
        BLAST = _blast;
        manager = _manager;
        weth = _weth;

        IERC20Rebasing(_weth).configure(YieldMode.CLAIMABLE);

        _blast.configureClaimableGas();

        BLAST_POINTS.configurePointsOperator(pointsOperator);
    }

    function setRebasingTokens(IERC20Rebasing[] calldata tokens, bool /* isRebasing */ ) external onlyManager {
        for (uint256 i = 0; i < tokens.length; i++) {
            // weth is configured on instantiation
            require(address(tokens[i]) != weth);
            tokens[i].configure(YieldMode.CLAIMABLE);
        }
    }

    function claimGas(uint256 minClaimRateBips) external onlyManager {
        BLAST.claimGasAtMinClaimRate(address(this), manager.feeCollector(), minClaimRateBips);
    }

    function claimRebasingTokensYield(IERC20Rebasing[] calldata tokens) external onlyManager {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20Rebasing token = tokens[i];
            require(rebasingTokens[token]);

            uint256 yieldToClaim = token.getClaimableAmount(address(this));
            require(yieldToClaim > 0);

            token.claim(manager.feeCollector(), yieldToClaim);
        }
    }
}
