// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../LiquidTokenStakingPool.sol";
import "../../interfaces/IManualClaimLiquidTokenStakingPool.sol";

contract ManualClaimLiquidTokenStakingPool is
    LiquidTokenStakingPool,
    IManualClaimLiquidTokenStakingPool
{
    uint256 internal _stashedForManualClaims;
    mapping(address => uint256) internal _manualClaims; // address => amount

    // reserve some gap for the future upgrades
    uint256[50 - 2] private __reserved;

    modifier notMarkerForManualClaim() virtual {
        require(
            _manualClaims[msg.sender] == 0,
            "LiquidTokenStakingPool: sender is marked for manual claim"
        );
        _;
    }

    function __ManualClaimPool_init() internal onlyInitializing {}

    /**
     * @dev Checks whether receiverAddress is marked for manual claim
     * @dev Might be overridden
     */
    function _beforeUnstake(
        address /* ownerAddress */,
        address receiverAddress,
        uint256 /* amount */
    ) internal virtual override(LiquidTokenStakingPool) {
        require(
            !isMarkedForManualClaim(receiverAddress),
            "LiquidTokenStakingPool: receiver is marked for manual claim"
        );
    }

    function unstakeBonds(
        uint256 amount
    )
        external
        virtual
        nonReentrant
        notMarkerForManualClaim
        bondStakingUnpaused
    {
        _unstakeBondsFor(msg.sender, amount);
    }

    function unstakeBondsFor(
        address receiverAddress,
        uint256 amount
    ) external virtual nonReentrant bondStakingUnpaused {
        _unstakeBondsFor(receiverAddress, amount);
    }

    function unstakeCerts(
        uint256 shares
    ) external virtual notMarkerForManualClaim nonReentrant {
        _unstakeCertsFor(msg.sender, shares);
    }

    function unstakeCertsFor(
        address receiverAddress,
        uint256 shares
    ) external virtual nonReentrant {
        _unstakeCertsFor(receiverAddress, shares);
    }

    function claimManually(address receiverAddress) external nonReentrant {
        require(
            receiverAddress != address(0),
            "LiquidTokenStakingPool: zero address"
        );
        uint256 amount = _manualClaims[receiverAddress];
        require(
            amount > 0,
            "LiquidTokenStakingPool: not marked for manual claim"
        );
        require(
            address(this).balance >= getStashedForManualClaims(),
            "LiquidTokenStakingPool: insufficient pool balance"
        );
        _stashedForManualClaims -= amount;
        _manualClaims[receiverAddress] = 0;
        // _markedForManualClaim[id] = address(0);
        bool result = _unsafeTransfer(receiverAddress, amount, false);
        require(
            result,
            "LiquidTokenStakingPool: failed to send rewards to receiverAddress"
        );
        emit RewardsClaimed(receiverAddress, msg.sender, amount);
    }

    function _setForManualClaim(address claimer, uint256 amount) internal {
        _stashedForManualClaims += amount;
        _manualClaims[claimer] += amount;

        emit ManualClaimExpected(claimer, amount);
    }

    function isMarkedForManualClaim(
        address claimer
    ) public view returns (bool) {
        return _manualClaims[claimer] != uint256(0);
    }

    function getForManualClaimOf(
        address claimer
    ) public view returns (uint256) {
        return _manualClaims[claimer];
    }

    function getStashedForManualClaims() public view returns (uint256) {
        return _stashedForManualClaims;
    }

    /// @dev Might be overridden
    function getFreeBalance() public view virtual override returns (uint256) {
        return
            address(this).balance < getStashedForManualClaims()
                ? 0
                : address(this).balance - getStashedForManualClaims();
    }
}
