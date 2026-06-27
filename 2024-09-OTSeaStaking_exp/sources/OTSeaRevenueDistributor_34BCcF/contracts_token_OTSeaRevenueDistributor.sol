/*
        [....     [... [......  [.. ..
      [..    [..       [..    [..    [..
    [..        [..     [..     [..         [..       [..
    [..        [..     [..       [..     [.   [..  [..  [..
    [..        [..     [..          [.. [..... [..[..   [..
      [..     [..      [..    [..    [..[.        [..   [..
        [....          [..      [.. ..    [....     [.. [...

    Revenue Distributor.

    https://otsea.io
    https://t.me/OTSeaPortal
    https://twitter.com/OTSeaERC20
*/

// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/libraries/OTSeaErrors.sol";
import "contracts/token/OTSeaStaking.sol";

/**
 * @notice OTSea ETH revenue distributor
 * @dev This contract collects revenue (in ETH) from v1 token fees and from the platform and distributes to stakes
 * periodically.
 *
 * The minimum distribution period between distributions is set in the contract by the minInterval variable. By default
 * this is set to 6 days 23 hours and 59 minutes, this is so that a CRON job can call this function approximately
 * every 7 days.
 *
 * To avoid this contract being fully centralized, any user can call the distribute() function (provided the minimum
 * period has been met), meaning that revenue can always be paid to stakers.
 */
contract OTSeaRevenueDistributor is Ownable {
    uint256 private constant MINIMUM_DISTRIBUTION = 0.0001 ether;
    uint256 private constant MINIMUM_STAKE = 1 ether;
    uint24 private constant MIN_EPOCH_TIME = 1 days;
    uint24 private constant MAX_EPOCH_TIME = 30 days;
    uint24 public minInterval = 7 days - 1 minutes;
    OTSeaStaking public stakingContract;

    error AlreadyInitialized();
    error NotInitialized();

    event Initialized(address stakingContract);
    event MinDistributionIntervalUpdated(uint24 time);

    /// @param _multiSigAdmin Multi-sig admin
    constructor(address _multiSigAdmin) Ownable(_multiSigAdmin) {}

    /**
     * @notice Initialize the contract
     * @param _stakingContract Staking contract
     */
    function initialize(OTSeaStaking _stakingContract) external onlyOwner {
        if (isInitialized()) revert AlreadyInitialized();
        if (address(_stakingContract) == address(0)) revert OTSeaErrors.InvalidAddress();
        stakingContract = _stakingContract;
        emit Initialized(address(_stakingContract));
    }

    /**
     * @notice Set the minimum interval between distributions
     * @param _time Minimum duration between distributions (in seconds, with a range between 1 - 30 days)
     */
    function setMinDistributionInterval(uint24 _time) external onlyOwner {
        if (_time < MIN_EPOCH_TIME || MAX_EPOCH_TIME < _time) revert OTSeaErrors.InvalidAmount();
        minInterval = _time;
        emit MinDistributionIntervalUpdated(_time);
    }

    /**
     * @notice Distribute all ETH in this contract to stakers in the stakingContract contract
     * @dev Anyone can call distribute after the first epoch has been ended by the owner, therefore a
     * minimum time interval is enforced
     */
    function distribute() external {
        if (!isInitialized()) revert NotInitialized();
        (uint32 epochNumber, OTSeaStaking.Epoch memory epoch) = stakingContract.getCurrentEpoch();
        if (epochNumber == 1) {
            if (msg.sender != stakingContract.owner()) revert OTSeaErrors.Unauthorized();
        } else if (block.timestamp < epoch.startedAt + minInterval) {
            revert OTSeaErrors.NotAvailable();
        }
        uint256 balance = address(this).balance;
        if (balance < MINIMUM_DISTRIBUTION || epoch.totalStake < MINIMUM_STAKE) {
            stakingContract.skipEpoch();
        } else {
            stakingContract.distribute{value: balance}();
        }
    }

    /**
     * @notice Check if the contract is initialized
     * @return bool true if initialized, false if not
     */
    function isInitialized() public view returns (bool) {
        return address(stakingContract) != address(0);
    }

    receive() external payable {}
}
