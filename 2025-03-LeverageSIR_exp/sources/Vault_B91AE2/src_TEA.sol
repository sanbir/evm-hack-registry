// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// Interfaces
import {IERC20} from "v2-core/interfaces/IERC20.sol";

// Libraries
import {SirStructs} from "./libraries/SirStructs.sol";
import {VaultExternal} from "./libraries/VaultExternal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Fees} from "./libraries/Fees.sol";
import {SystemConstants} from "./libraries/SystemConstants.sol";

// Contracts
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {SystemState} from "./SystemState.sol";

/** @dev Highly modified contract version from Solmate's ERC-1155.\n
    This contract manages all the LP tokens of all vaults in the protocol.
 */
contract TEA is SystemState {
    error TEAMaxSupplyExceeded();
    error NotAuthorized();
    error LengthMismatch();
    error UnsafeRecipient();

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] vaultIds,
        uint256[] amounts
    );

    struct TotalSupplyAndBalanceVault {
        uint128 totalSupply;
        uint128 balanceVault;
    }

    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    mapping(address => mapping(uint256 => uint256)) internal balances;

    /*  Because the protocol owned liquidity (POL) is updated on every mint/burn of TEA, we packed both values,
        totalSupply and the POL balance, into a single uint256 to save gas on SLOADs.
        POL is TEA owned by this same contract.
        Fortunately, the max supply of TEA fits in 128 bits, so we can use the other 128 bits for POL.
     */
    mapping(uint256 vaultId => TotalSupplyAndBalanceVault) internal totalSupplyAndBalanceVault;

    SirStructs.VaultParameters[] internal _paramsById; // Never used in Vault.sol. Just for users to access vault parameters by vault ID.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(address systemControl, address sir) SystemState(systemControl, sir) {}

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Returns vault parameters by vault ID.
    function paramsById(uint48 vaultId) external view returns (SirStructs.VaultParameters memory) {
        return _paramsById[vaultId];
    }

    /// @notice Returns the number of initialized vaults.
    function numberOfVaults() external view returns (uint48) {
        return uint48(_paramsById.length - 1);
    }

    /// @notice The total circulating supply of TEA.
    function totalSupply(uint256 vaultId) external view returns (uint256) {
        return totalSupplyAndBalanceVault[vaultId].totalSupply;
    }

    /// @notice The total circulating supply of TEA excluding POL.
    function supplyExcludeVault(uint256 vaultId) internal view override returns (uint256) {
        TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
        return totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault;
    }

    function uri(uint256 vaultId) external view returns (string memory) {
        return VaultExternal.teaURI(_paramsById, vaultId, totalSupplyAndBalanceVault[vaultId].totalSupply);
    }

    /// @notice Returns the balance of the given `account` for the given `vaultId`.
    function balanceOf(address account, uint256 vaultId) public view override returns (uint256) {
        return account == address(this) ? totalSupplyAndBalanceVault[vaultId].balanceVault : balances[account][vaultId];
    }

    /// @notice Returns the balances of multiple vault ID's
    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external view returns (uint256[] memory balances_) {
        if (owners.length != vaultIds.length) revert LengthMismatch();

        balances_ = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances_[i] = balanceOf(owners[i], vaultIds[i]);
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c; // ERC165 Interface ID for ERC1155MetadataURI
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Grants or revokes permission for `operator` to delegate token transfers on behalf of `account`.
     */
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /**
     * @notice Transfers `amount` tokens in `vaultId` from `from` to `to`.
     */
    function safeTransferFrom(address from, address to, uint256 vaultId, uint256 amount, bytes calldata data) external {
        assert(from != address(this));
        if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();

        // Update balances
        _updateBalances(from, to, vaultId, amount);

        emit TransferSingle(msg.sender, from, to, vaultId, amount);

        if (
            to.code.length == 0
                ? to == address(0)
                : (to != address(this) &&
                    ERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, vaultId, amount, data) !=
                    ERC1155TokenReceiver.onERC1155Received.selector)
        ) revert UnsafeRecipient();
    }

    /**
     * @notice Transfers `amounts` tokens in `vaultIds` from `from` to `to`.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata vaultIds,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        unchecked {
            assert(from != address(this));
            if (vaultIds.length != amounts.length) revert LengthMismatch();
            if (msg.sender != from && !isApprovedForAll[from][msg.sender]) revert NotAuthorized();

            for (uint256 i = 0; i < vaultIds.length; ++i) {
                // Update balances
                _updateBalances(from, to, vaultIds[i], amounts[i]);
            }

            emit TransferBatch(msg.sender, from, to, vaultIds, amounts);

            if (
                to.code.length == 0
                    ? to == address(0)
                    : (to != address(this) &&
                        ERC1155TokenReceiver(to).onERC1155BatchReceived(msg.sender, from, vaultIds, amounts, data) !=
                        ERC1155TokenReceiver.onERC1155BatchReceived.selector)
            ) revert UnsafeRecipient();
        }
    }

    /**
     * @dev This function is called when a user mints TEA.
     * It splits the collateral amount between the minter and POL.
     * It also updates SIR rewards in case this vault is elligible for them.
     */
    function mint(
        address minter,
        address collateral,
        uint48 vaultId,
        SirStructs.SystemParameters memory systemParams_,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        SirStructs.Reserves memory reserves,
        uint144 collateralDeposited
    ) internal returns (SirStructs.Fees memory fees, uint256 amount) {
        uint256 amountToPOL;
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfTo = balances[minter][vaultId];

            // Update SIR issuance of gentlemen
            LPersBalances memory lpersBalances = LPersBalances(minter, balanceOfTo, address(this), 0);
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_.cumulativeTax,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                lpersBalances
            );

            // Total amount of TEA to mint (to split between minter and POL)
            // We use variable amountToPOL for efficiency, not because it is just for POL
            amountToPOL = totalSupplyAndBalanceVault_.totalSupply == 0 // By design reserveLPers can never be 0 unless it is the first mint ever
                ? _amountFirstMint(collateral, collateralDeposited + reserves.reserveLPers) // In the first mint, reserveLPers contains orphaned fees from apes
                : FullMath.mulDiv(totalSupplyAndBalanceVault_.totalSupply, collateralDeposited, reserves.reserveLPers);

            // Check that total supply does not overflow
            if (amountToPOL > SystemConstants.TEA_MAX_SUPPLY - totalSupplyAndBalanceVault_.totalSupply) {
                revert TEAMaxSupplyExceeded();
            }

            // Split collateralDeposited between minter and POL
            fees = Fees.feeMintTEA(collateralDeposited, systemParams_.lpFee.fee);

            // Minter's share of TEA
            amount = FullMath.mulDiv(
                amountToPOL,
                fees.collateralInOrWithdrawn,
                totalSupplyAndBalanceVault_.totalSupply == 0
                    ? collateralDeposited + reserves.reserveLPers // In the first mint, reserveLPers contains orphaned fees from apes
                    : collateralDeposited
            );

            // POL's share of TEA
            amountToPOL -= amount;

            // Update total supply and protocol balance
            balances[minter][vaultId] = balanceOfTo + amount;
            totalSupplyAndBalanceVault_.balanceVault += uint128(amountToPOL);
            totalSupplyAndBalanceVault_.totalSupply += uint128(amount + amountToPOL);

            // Store total supply
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;
        }

        // Update reserves
        reserves.reserveLPers += collateralDeposited;

        // Emit (mint) transfer events
        emit TransferSingle(minter, address(0), minter, vaultId, amount);
        emit TransferSingle(minter, address(0), address(this), vaultId, amountToPOL);
    }

    /**
     * @dev This function is called when a user burns TEA.
     * @dev It also updates SIR rewards in case this vault is elligible for them.
     */
    function burn(
        uint48 vaultId,
        SirStructs.SystemParameters memory systemParams_,
        SirStructs.VaultIssuanceParams memory vaultIssuanceParams_,
        SirStructs.Reserves memory reserves,
        uint256 amount
    ) internal returns (SirStructs.Fees memory fees) {
        unchecked {
            // Loads supply and balance of TEA
            TotalSupplyAndBalanceVault memory totalSupplyAndBalanceVault_ = totalSupplyAndBalanceVault[vaultId];
            uint256 balanceOfFrom = balances[msg.sender][vaultId];

            // Check we are not burning more than the balance
            require(amount <= balanceOfFrom);

            // Update SIR issuance
            updateLPerIssuanceParams(
                false,
                vaultId,
                systemParams_.cumulativeTax,
                vaultIssuanceParams_,
                totalSupplyAndBalanceVault_.totalSupply - totalSupplyAndBalanceVault_.balanceVault,
                LPersBalances(msg.sender, balanceOfFrom, address(this), 0)
            );

            // Compute amount of collateral
            fees.collateralInOrWithdrawn = uint144(
                FullMath.mulDiv(reserves.reserveLPers, amount, totalSupplyAndBalanceVault_.totalSupply)
            );

            // Update balance and total supply
            balances[msg.sender][vaultId] = balanceOfFrom - amount;
            totalSupplyAndBalanceVault_.totalSupply -= uint128(amount);

            // Update reserves
            reserves.reserveLPers -= fees.collateralInOrWithdrawn;

            // Update total supply and vault balance
            totalSupplyAndBalanceVault[vaultId] = totalSupplyAndBalanceVault_;

            // Emit transfer event
            emit TransferSingle(msg.sender, msg.sender, address(0), vaultId, amount);
        }
    }

    /*////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @dev Makes sure that even if the entire supply of the collateral token was deposited into the vault,
     * the amount of TEA minted is less than the maximum supply of TEA.
     */
    function _amountFirstMint(address collateral, uint144 collateralDeposited) private view returns (uint256 amount) {
        uint256 collateralTotalSupply = IERC20(collateral).totalSupply();
        /** When possible assign siz 0's to the TEA balance per unit of collateral to mitigate inflation attacks.
            If not possible mint as much as TEA as possible while forcing that if all collateral was minted, it would not overflow the TEA maximum supply.
         */
        amount = collateralTotalSupply > SystemConstants.TEA_MAX_SUPPLY / 1e6
            ? FullMath.mulDiv(SystemConstants.TEA_MAX_SUPPLY, collateralDeposited, collateralTotalSupply)
            : collateralDeposited * 1e6;
    }

    /**'
     * @dev This helper function ensures that the balance of the vault (POL)
     * is not stored in the regular variable balances.
     */
    function _setBalance(address account, uint256 vaultId, uint256 balance) private {
        if (account == address(this)) totalSupplyAndBalanceVault[vaultId].balanceVault = uint128(balance);
        else balances[account][vaultId] = balance;
    }

    /**
     * @dev Helper function for updating balances and SIR rewards when transfering TEA between accounts.
     */
    function _updateBalances(address from, address to, uint256 vaultId, uint256 amount) private {
        // Update SIR issuances
        LPersBalances memory lpersBalances = LPersBalances(from, balances[from][vaultId], to, balanceOf(to, vaultId));
        updateLPerIssuanceParams(
            false,
            vaultId,
            _systemParams.cumulativeTax,
            vaultIssuanceParams[vaultId],
            supplyExcludeVault(vaultId),
            lpersBalances
        );

        // Update balances
        lpersBalances.balance0 -= amount;
        if (from != to) {
            balances[from][vaultId] = lpersBalances.balance0;
            unchecked {
                _setBalance(to, vaultId, lpersBalances.balance1 + amount);
            }
        }
    }

    /*////////////////////////////////////////////////////////////////
                        SYSTEM STATE VIRTUAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function cumulativeSIRPerTEA(uint256 vaultId) public view override returns (uint176 cumulativeSIRPerTEAx96) {
        return
            cumulativeSIRPerTEA(_systemParams.cumulativeTax, vaultIssuanceParams[vaultId], supplyExcludeVault(vaultId));
    }
}
