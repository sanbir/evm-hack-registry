// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * ____________________________
 * Description:
 * GoldPesa (GPX) - An advanced form of money
 * __________________________________
 */
contract GPX is ERC20, ERC20Permit {

    // =======================
    // ======= ERRORS ========
    // =======================

    /// @notice Thrown when an unauthorized address attempts to transfer GPX tokens to the treasury.
    error UnauthorizedTreasuryTransfer(address from, address to);

    // =======================
    // ======= EVENTS ========
    // =======================

    /// @notice Emitted when transfer fees are distributed during a GPX token transfer
    /// @param from The address that initiated the transfer
    /// @param feeToPawn The amount of the fee distributed to the Pawn
    /// @param feeToMines The amount of the fee distributed to the GoldPesa Mine
    /// @param feeToTreasury The amount of the fee distributed to the GPX Treasury
    event FeeDistributed(
        address indexed from, 
        uint256 feeToPawn, 
        uint256 feeToMines,
        uint256 feeToTreasury
    );

    // =================================
    // ========== CONSTANTS ============
    // =================================

    /// @notice Token Name
    string public constant Name = "GoldPesa";
    /// @notice Token Symbol
    string public constant Symbol = "GPX";
    /// @notice GPX Fixed Supply
    uint256 public constant FixedSupply = 100_000_000;
    /// @notice Fee On Transfer Percentage
    uint256 public constant FeeOnTransfer = 1;

    // =================================
    // ======= PUBLIC STATE GETTERS ====
    // =================================

    /// @notice The Pawn Contract
    address public pawn;
    /// @notice Goldpesa Mines Treasury Contract
    address public mines;
    /// @notice GoldPesa Vault Contract
    address public vault;
    /// @notice GPX Treasury Contract
    address public immutable treasury;
     /// @notice GPX Hook Contract
    address public immutable gpxHook;
    /// @notice Uniswap V4 Universal Router
    address public immutable router;
    /// @notice Uniswap V4 Pool Manager
    address public immutable poolManager;

    // =================================
    // ==== PRIVATE STATE VARIABLES ====
    // =================================

    /// @notice Address set flag to prevent multiple calls
    bool private addressesSet;

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @dev Initializes the GPX token contract by setting key contract addresses and minting the fixed supply.
     * The entire fixed supply is minted to the specified GPX Hook contract address.
     *
     * @param _treasury GoldPesa Treasury address
     * @param _gpxHook GPX Hook address
     * @param _router Uniswap V4 Universal Router address
     * @param _poolManager Uniswap V4 Pool Manager address
     */
    constructor(
        address _treasury,
        address _gpxHook,
        address _router,
        address _poolManager
    ) ERC20(Name, Symbol) ERC20Permit(Name) {
        treasury = _treasury;
        gpxHook = _gpxHook;
        router = _router;
        poolManager = _poolManager;
        
        // Mint the entire fixed supply to the GPX Hook contract
        _mint(_gpxHook, FixedSupply * (10**(uint256(decimals()))));
    }

    // ============================
    // ======= MAIN FUNCTION ======
    // ============================

    /**
     * @dev Internal function that overrides the ERC20 `_update` method to implement a fee-on-transfer mechanism.
     * Applies a 1% fee on all token transfers, excluding minting and burning operations, and transfers involving exempt addresses.
     * The collected fee is distributed among the Pawn, Mines, and Treasury contracts.
     *
     * Fee Distribution:
     * - 25% to the Pawn contract
     * - 25% to the Mines contract
     * - 50% to the Treasury contract
     *
     * Emits a {FeeDistributed} event indicating the fee distribution details.
     *
     * @param from The address initiating the transfer.
     * @param to The address receiving the tokens.
     * @param value The amount of tokens to be transferred before fee deduction.
     */
    function _update(
        address from, 
        address to,
        uint256 value
    ) internal virtual override {
        // Only GPXHook can send GPX to the treasury
        if (from != gpxHook && to == treasury) {
            revert UnauthorizedTreasuryTransfer(from, to);
        }

        // Apply fee on transfer for all transactions except for minting and burning
        if (from != address(0) && to != address(0)) {
            // Exempt specific addresses from the fee on transfer
            if (!(from == gpxHook || to == gpxHook || 
                  from == router || to == router || 
                  from == poolManager || to == poolManager || 
                  from == vault || to == vault || 
                  from == pawn || to == pawn || 
                  from == mines || to == mines || 
                  from == treasury || to == treasury)
            ) {
                if (value > 0) {
                    // Calculate the total fee based on the FeeOnTransfer rate
                    uint256 fee = (value * FeeOnTransfer) / 100;

                    // Split the fee between pawn, mines and treasury contract
                    uint256 feeToPawn = fee / 4;
                    uint256 feeToMines = fee / 4;
                    uint256 feeToTreasury = fee - feeToPawn - feeToMines; 

                    // Transfer the fees to the respective recipients
                    super._update(from, pawn, feeToPawn);
                    super._update(from, mines, feeToMines);
                    super._update(from, treasury, feeToTreasury);

                    // Emit Fee distribution event for transparency
                    emit FeeDistributed(from, feeToPawn, feeToMines, feeToTreasury);

                    // Adjust the transfer amount after deducting the total fee
                    value -= fee;
                }
            }
        }

        super._update(from, to, value);
    }

    /**
     * @dev Sets the addresses for the Pawn, Mines, and Vault contracts.
     * Can only be called once by the authorized GPXHooks contract to prevent unauthorized modifications.
     *
     * Requirements:
     * - The addresses must not have been set previously.
     * - The caller must be the authorized GPXHooks contract.
     *
     * @param _pawn Address of the Pawn contract.
     * @param _mines Address of the Mines contract.
     * @param _vault Address of the Vault contract.
     */
    function setAddresses(address _pawn, address _mines, address _vault) external {
        require(!addressesSet, "Addresses already set");
        require(msg.sender == gpxHook, "Unauthorized caller");

        pawn = _pawn;
        mines = _mines;
        vault = _vault;
        addressesSet = true;
    }
}