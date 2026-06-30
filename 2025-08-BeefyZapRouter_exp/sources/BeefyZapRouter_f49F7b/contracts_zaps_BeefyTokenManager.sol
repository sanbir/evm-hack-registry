// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";
import { ZapErrors } from "./ZapErrors.sol";

/**
 * @title Token manager
 * @author kexley, Beefy
 * @notice Token manager handles the token approvals for the zap router
 * @dev Users should approve this contract instead of the zap router to handle the input ERC20 tokens
 */
contract BeefyTokenManager is ZapErrors {
    using SafeERC20 for IERC20;

    /**
     * @notice Zap router immutable address
     */
    address public immutable zap;

    /**
     * @dev This contract is created in the constructor of the zap router
     */
    constructor() {
        zap = msg.sender;
    }

    /**
     * @notice Pulls tokens from a user and transfers them directly to the zap router
     * @dev Only the token owner can call this function indirectly via the zap router
     * @param _user Address to pull tokens from
     * @param _inputs Token addresses and amounts to pull
     */
    function pullTokens(address _user, IBeefyZapRouter.Input[] calldata _inputs) external {
        if (msg.sender != zap) revert CallerNotZap(msg.sender);
        uint256 inputLength = _inputs.length;
        for (uint256 i; i < inputLength;) {
            IBeefyZapRouter.Input calldata input = _inputs[i];
            unchecked {
                ++i;
            }

            if (input.token == address(0)) continue;
            IERC20(input.token).safeTransferFrom(_user, msg.sender, input.amount);
        }
    }
}
