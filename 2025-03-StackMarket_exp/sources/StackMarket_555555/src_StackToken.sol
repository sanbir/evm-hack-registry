// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @title StackToken
 * @notice An implementation of personalized ERC20 tokens with market integration
 * @author stack.so
 */
contract StackToken is ERC20 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERRORS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Core error states
    error StackToken__AlreadyInitialized();
    error StackToken__InvalidValue();
    error StackToken__InvalidName();
    error StackToken__InvalidSymbol();
    error StackToken__AccountOnly();
    error StackToken__ZeroAddress();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Core state change events
    event NameUpdated(string indexed oldName, string indexed newName);
    event SymbolUpdated(string indexed oldSymbol, string indexed newSymbol);
    event AutoBuyExecuted(address indexed buyer, uint256 amount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Maximum token supply (10M with 18 decimals)
    uint256 public constant MAX_SUPPLY = 10_000_000 ether;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STORAGE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Core token configuration
    string private _name; // Token name
    string private _symbol; // Token symbol

    IMarket public market; // Market contract reference
    address public account; // Associated account

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures caller is the associated account
    modifier onlyAccount() {
        if (msg.sender != account) {
            revert StackToken__AccountOnly();
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Initializer                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function initialize(string memory tokenName, string memory tokenSymbol, address tokenOwner) external {
        if (account != address(0)) revert StackToken__AlreadyInitialized();
        if (bytes(tokenName).length == 0) revert StackToken__InvalidName();
        if (bytes(tokenSymbol).length == 0) revert StackToken__InvalidSymbol();
        if (tokenOwner == address(0)) revert StackToken__ZeroAddress();

        _name = tokenName;
        _symbol = tokenSymbol;
        account = tokenOwner;
        market = IMarket(msg.sender);
        _mint(msg.sender, MAX_SUPPLY);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     TOKEN METADATA                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Token name
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Token symbol
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Token decimals (fixed at 18)
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    TOKEN OPERATIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// /// @notice Update token name (owner only)
    /// @param newName New name to set
    function setName(string calldata newName) external onlyAccount {
        if (bytes(newName).length == 0) revert StackToken__InvalidName();

        emit NameUpdated(_name, newName);
        _name = newName;
    }

    /// @notice Updates the token symbol
    /// @param newSymbol New symbol to set
    function setSymbol(string calldata newSymbol) external onlyAccount {
        if (bytes(newSymbol).length == 0) revert StackToken__InvalidSymbol();

        emit SymbolUpdated(_symbol, newSymbol);
        _symbol = newSymbol;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     AUTO-BUY LOGIC                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Auto-buy tokens when receiving ETH
    receive() external payable {
        if (msg.value == 0) revert StackToken__InvalidValue();

        // Forward ETH to market for auto-buy
        // Note: tx.origin usage is safe here as it only specifies token recipient
        market.buyFor{value: msg.value}(
            account, // Token owner
            0, // No minimum tokens (accepts slippage)
            tx.origin, // Token recipient
            0 // No price limit
        );

        emit AutoBuyExecuted(tx.origin, msg.value);
    }
}
