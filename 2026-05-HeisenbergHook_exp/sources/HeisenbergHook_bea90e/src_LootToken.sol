// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal interface the hook must expose for $LOOT redemption.
interface ILootTreasury {
    /// @notice Total ETH held by the treasury that backs $LOOT redemptions.
    function heistTreasuryETH() external view returns (uint256);

    /// @notice Pay out `ethAmount` to `to` against a $LOOT burn. Only callable by the configured Loot token.
    /// @param to Recipient of the ETH.
    /// @param ethAmount Amount of ETH (wei) to release from the treasury.
    function payRedemption(address to, uint256 ethAmount) external;
}

/// @title LootToken
/// @notice The $LOOT ERC-20. Mintable only by the configured `HOOK`; redeemable for ETH from the hook's treasury.
/// @dev Supply grows when heists resolve cleanly (hook calls `mintToHolder`) and shrinks when holders call `redeem`.
contract LootToken is ERC20 {
    /// @notice The hook contract authorized to mint and to pay out redemptions.
    address public hook;
    /// @notice Address allowed to set the hook exactly once.
    address public initializer;
    /// @notice Cumulative ETH historically paid out for $LOOT redemptions.
    uint256 public totalRedeemed;

    /// @notice The portion of the treasury (basis points) redeemable at any time. 8500 = 85%.
    uint16 public constant REDEMPTION_DISCOUNT_BP = 8500;

    /// @notice Emitted on a successful redemption.
    /// @param holder The redeemer.
    /// @param lootBurned Amount of $LOOT burned.
    /// @param ethPaid Amount of ETH (wei) released from the treasury.
    event Redeemed(address indexed holder, uint256 lootBurned, uint256 ethPaid);

    /// @notice Reverts when a non-hook caller attempts a privileged action.
    error OnlyHook();
    /// @notice Reverts when a non-initializer tries to set `hook`, or when `setHook` is called twice.
    error HookAlreadySet();
    /// @notice Reverts when a redemption would pay zero ETH.
    error NothingToRedeem();

    /// @notice Restricts a function to the configured hook.
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /// @notice Deploys $LOOT with zero initial supply.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        initializer = msg.sender;
    }

    /// @notice Wires the hook contract. Can only be called once, by the deployer.
    /// @param _hook Address of the hook contract.
    function setHook(address _hook) external {
        if (msg.sender != initializer || hook != address(0)) revert HookAlreadySet();
        hook = _hook;
        initializer = address(0);
    }

    /// @notice Mints $LOOT to a single recipient. Only callable by the hook.
    /// @param to Recipient.
    /// @param amount Amount in wei.
    function mintToHolder(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    /// @notice Burns `amount` $LOOT from the caller and pulls ETH from the hook's treasury at the current rate.
    /// @param amount Amount of $LOOT (in wei) to burn.
    /// @return ethAmount The amount of ETH paid to the caller.
    function redeem(uint256 amount) external returns (uint256 ethAmount) {
        ethAmount = previewRedemption(amount);
        if (ethAmount == 0) revert NothingToRedeem();

        _burn(msg.sender, amount);
        totalRedeemed += ethAmount;
        ILootTreasury(hook).payRedemption(msg.sender, ethAmount);

        emit Redeemed(msg.sender, amount, ethAmount);
    }

    /// @notice ETH per 1e18 $LOOT at the current treasury and supply.
    /// @return rate ETH (wei) paid for 1e18 $LOOT.
    function getRedemptionRate() external view returns (uint256 rate) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 redeemablePool = (ILootTreasury(hook).heistTreasuryETH() * REDEMPTION_DISCOUNT_BP) / 10_000;
        rate = (redeemablePool * 1e18) / supply;
    }

    /// @notice Computes the ETH that would be paid for burning `lootAmount` $LOOT right now.
    /// @param lootAmount Amount of $LOOT (in wei) to preview.
    /// @return ethAmount ETH (wei) that would be received.
    function previewRedemption(uint256 lootAmount) public view returns (uint256 ethAmount) {
        uint256 supply = totalSupply();
        if (supply == 0 || lootAmount == 0) return 0;
        uint256 redeemablePool = (ILootTreasury(hook).heistTreasuryETH() * REDEMPTION_DISCOUNT_BP) / 10_000;
        ethAmount = (redeemablePool * lootAmount) / supply;
    }
}
