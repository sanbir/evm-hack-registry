// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/ICertificateToken.sol";
import "../interfaces/IBearingToken.sol";
import "../interfaces/IEarnConfig.sol";
import "../interfaces/ILiquidTokenStakingPool.sol";

abstract contract LiquidTokenStakingPool is
    ILiquidTokenStakingPool,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    /**
     * @dev external contracts
     */
    IBearingToken internal _bearingToken;
    ICertificateToken internal _certificateToken;
    IEarnConfig internal _earnConfig;

    /**
     * @dev compact size, should be multiplied by 1 gwei
     */
    uint64 private minimumStake;

    uint64 private _minimumUnstake;

    // reserve some gap for the future upgrades
    uint256[50 - 5] private __reserved;

    modifier onlyGovernance() virtual {
        require(
            msg.sender == _earnConfig.getGovernanceAddress(),
            "LiquidTokenStakingPool: only governance allowed"
        );
        _;
    }

    modifier onlyConsensus() virtual {
        require(
            msg.sender == _earnConfig.getConsensusAddress(),
            "LiquidTokenStakingPool: only consensus allowed"
        );
        _;
    }

    modifier bondStakingUnpaused() virtual {
        require(
            !_earnConfig.isBondStakingPaused(),
            "LiquidTokenStakingPool: bond staking is paused"
        );
        _;
    }

    function __LiquidTokenStakingPool_init(
        IEarnConfig earnConfig
    ) internal onlyInitializing {
        _earnConfig = earnConfig;
    }

    receive() external payable virtual {
        emit Received(msg.sender, msg.value);
    }

    function setBearingToken(
        address newValue
    ) external override onlyGovernance {
        address prevValue = address(_bearingToken);
        _bearingToken = IBearingToken(newValue);
        emit BearingTokenChanged(prevValue, newValue);
    }

    function setCertificateToken(
        address newValue
    ) external override onlyGovernance {
        address prevValue = address(_certificateToken);
        _certificateToken = ICertificateToken(newValue);
        emit CertificateTokenChanged(prevValue, newValue);
    }

    function setMinimumStake(
        uint256 newValue
    ) external virtual override onlyGovernance {
        require(
            newValue % 1 gwei == 0,
            "LiquidTokenStakingPool: value should be multiplied of gwei"
        );
        uint256 prevValue = getMinStake();
        minimumStake = uint64(newValue / 1 gwei);
        require(
            minimumStake * 1 gwei == newValue,
            "LiquidTokenStakingPool: overflow"
        );
        emit MinimumStakeChanged(prevValue, newValue);
    }

    function setMinimumUnstake(
        uint256 newValue
    ) external virtual override onlyGovernance {
        require(
            newValue % 1 gwei == 0,
            "LiquidTokenStakingPool: value should be multiplied of gwei"
        );
        uint256 prevValue = getMinUnstake();
        _minimumUnstake = uint64(newValue / 1 gwei);
        require(
            _minimumUnstake * 1 gwei == newValue,
            "LiquidTokenStakingPool: overflow"
        );
        emit MinimumUnstakeChanged(prevValue, newValue);
    }

    function getMinStake() public view virtual override returns (uint256) {
        return uint256(minimumStake) * 1 gwei;
    }

    function getMinUnstake() public view virtual override returns (uint256) {
        return uint256(_minimumUnstake) * 1 gwei;
    }

    function stakeBonds()
        external
        payable
        override
        nonReentrant
        bondStakingUnpaused
    {
        _stakeBonds(msg.sender, msg.value);
    }

    function stakeCerts() external payable override nonReentrant {
        _stakeCerts(msg.sender, msg.value);
    }

    function _stakeCerts(address staker, uint256 amount) internal {
        uint256 shares = _certificateToken.bondsToShares(amount);
        _stake(staker, amount, shares, false);
        _bearingToken.unlockSharesFor(staker, shares);
        _afterStake(staker, amount, shares);
    }

    function _stakeBonds(address staker, uint256 amount) internal {
        uint256 shares = _bearingToken.bondsToShares(amount);
        _stake(staker, amount, shares, true);
        _afterStake(staker, amount, shares);
    }

    function _stake(
        address staker,
        uint256 amount,
        uint256 shares,
        bool isRebasing
    ) internal {
        _beforeStake(staker, amount, shares);
        require(
            amount >= getMinStake(),
            "LiquidTokenStakingPool: value must be greater than min amount"
        );
        _certificateToken.mint(address(_bearingToken), shares);
        _bearingToken.mint(staker, shares);
        emit Staked(staker, amount, shares, isRebasing);
    }

    function _beforeStake(
        address account,
        uint256 amount,
        uint256 shares
    ) internal virtual {}

    function _afterStake(
        address account,
        uint256 amount,
        uint256 shares
    ) internal virtual {}

    /**
     * @notice burns amount of bearing from msg.sender
     * @notice returns native or ERC20 token immediately or via queue
     * @param receiverAddress address for receiving unstaked funds
     * @param amount amount of bearing token to unstake
     */
    function _unstakeBondsFor(
        address receiverAddress,
        uint256 amount
    ) internal {
        address ownerAddress = msg.sender;
        uint256 shares = _bearingToken.bondsToShares(amount);
        require(
            amount >= getMinUnstake(),
            "LiquidTokenStakingPool: value must be greater than min amount"
        );
        require(
            _bearingToken.balanceOf(ownerAddress) >= amount,
            "LiquidTokenStakingPool: cannot unstake more than have on address"
        );
        _beforeUnstake(ownerAddress, receiverAddress, amount);
        _certificateToken.burn(address(_bearingToken), shares);
        _bearingToken.burn(ownerAddress, shares);
        _afterUnstake(ownerAddress, receiverAddress, amount);
        emit Unstaked(ownerAddress, receiverAddress, amount, shares, true);
    }

    /**
     * @notice Burns amount of certificate from msg.sender
     * @notice Returns native token immediately or via queue
     * @param receiverAddress address for receiving unstaked funds
     * @param shares amount of certificate token to unstake
     */
    function _unstakeCertsFor(
        address receiverAddress,
        uint256 shares
    ) internal {
        address ownerAddress = msg.sender;
        uint256 amount = _certificateToken.sharesToBonds(shares);
        require(
            amount >= getMinUnstake(),
            "LiquidTokenStakingPool: value must be greater than min amount"
        );
        require(
            _certificateToken.balanceOf(ownerAddress) >= shares,
            "LiquidTokenStakingPool: cannot unstake more than have on address"
        );
        _beforeUnstake(ownerAddress, receiverAddress, amount);
        _certificateToken.burn(ownerAddress, shares);
        _afterUnstake(ownerAddress, receiverAddress, amount);
        emit Unstaked(ownerAddress, receiverAddress, amount, shares, false);
    }

    /**
     * @dev Might be checked whether the amount matches some restrictions
     * @dev Might be checked the account for manual witdrawal requests
     */
    function _beforeUnstake(
        address ownerAddress,
        address receiverAddress,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Might be set for pending (queue)
     * @dev Might be distributed immediately
     */
    function _afterUnstake(
        address ownerAddress,
        address receiverAddress,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Unsafe transfer with gas limit if necessary
     * @notice The solution was received from bnb bounty program
     */
    function _unsafeTransfer(
        address receiverAddress,
        uint256 amount,
        bool limit
    ) internal virtual returns (bool) {
        address payable wallet = payable(receiverAddress);
        bool success;
        if (limit) {
            assembly {
                success := call(10000, wallet, amount, 0, 0, 0, 0)
            }
            return success;
        }
        (success, ) = wallet.call{value: amount}("");
        return success;
    }

    function getFreeBalance() public view virtual returns (uint256) {
        return address(this).balance;
    }

    /**
     * @return Bearing token address
     * @return Certificate token address
     */
    function getTokens() external view virtual returns (address, address) {
        return (address(_bearingToken), address(_certificateToken));
    }
}
