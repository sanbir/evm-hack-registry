//SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IXToken.sol";

/**
 * @title XTokenWrapper
 * @author Protofire
 * @dev Contract module which provides the functionalities for wrapping tokens into the corresponding
 * XToken and unwrapping XTokens giving back the corresponding Token.
 *
 */
contract XTokenWrapper is AccessControl, ERC1155Holder {
    using SafeERC20 for IERC20;

    address public constant ETH_TOKEN_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    bytes32 public constant REGISTRY_MANAGER_ROLE = keccak256("REGISTRY_MANAGER_ROLE");

    /**
     * @dev Token to xToken registry.
     */
    mapping(address => address) public tokenToXToken;

    /**
     * @dev xToken to Token registry.
     */
    mapping(address => address) public xTokenToToken;

    /**
     * @dev Emitted when `asset` is disallowed.
     */
    event RegisterToken(address indexed token, address indexed xToken);

    /**
     * @dev Grants the contract deployer the default admin role.
     *
     */
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Grants REGISTRY_MANAGER_ROLE to `_registryManager`.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function setRegistryManager(address _registryManager) external {
        grantRole(REGISTRY_MANAGER_ROLE, _registryManager);
    }

    /**
     * @dev Registers a new xToken associated to the ERC20 which it will be wrapping.
     *
     * Requirements:
     *
     * - the caller must have REGISTRY_MANAGER_ROLE.
     * - `_token` cannot be the zero address.
     * - `_xToken` cannot be the zero address.
     *
     * @param _token The address of the ERC20 being wrapped.
     * @param _xToken The address of xToken.
     */
    function registerToken(address _token, address _xToken) external {
        require(hasRole(REGISTRY_MANAGER_ROLE, _msgSender()), "must have registry manager role");
        require(_token != address(0), "token is the zero address");
        require(_xToken != address(0), "xToken is the zero address");

        emit RegisterToken(_token, _xToken);
        tokenToXToken[_token] = _xToken;
        xTokenToToken[_xToken] = _token;
    }

    /**
     * @dev Wraps `_token` into its associated xToken.
     *
     * It requires prior approval.
     *
     * Requirements:
     *
     * - `_token` should be registered.
     *
     * @param _token The address of the ERC20 being wrapped.
     *               {ETH_TOKEN_ADDRESS} in case of wrapping ETH
     * @param _amount The amount to wrap.
     */
    function wrap(address _token, uint256 _amount) external payable returns (bool) {
        address xTokenAddress = tokenToXToken[_token];
        require(xTokenAddress != address(0), "token is not registered");

        if (_token != ETH_TOKEN_ADDRESS) {
            IERC20(_token).safeTransferFrom(_msgSender(), address(this), _amount);
        }

        uint256 amount = _token != ETH_TOKEN_ADDRESS ? _amount : msg.value;

        require(amount > 0, "amount to wrap should be positive");

        IXToken(xTokenAddress).mint(_msgSender(), amount);

        return true;
    }

    /**
     * @dev Unwraps `_xToken`.
     *
     * Requirements:
     *
     * - `_xToken` should be registered.
     * - `_amonut` should be gt 0.
     *
     * @param _xToken The address of the ERC20 being wrapped.
     * @param _amount The amount to unwrap.
     */
    function unwrap(address _xToken, uint256 _amount) external returns (bool) {
        address tokenAddress = xTokenToToken[_xToken];
        require(tokenAddress != address(0), "xToken is not registered");
        require(_amount > 0, "amount to wrap should be positive");

        IXToken(_xToken).burnFrom(_msgSender(), _amount);

        if (tokenAddress != ETH_TOKEN_ADDRESS) {
            IERC20(tokenAddress).safeTransfer(_msgSender(), _amount);
        } else {
            // solhint-disable-next-line
            (bool sent, ) = msg.sender.call{ value: _amount }("");
            require(sent, "Failed to send Ether");
        }

        return true;
    }
}
