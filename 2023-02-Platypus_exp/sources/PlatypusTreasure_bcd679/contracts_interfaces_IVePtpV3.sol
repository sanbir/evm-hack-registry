// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import './IVeERC20.sol';

/**
 * @dev Interface of the VePtp
 */
interface IVePtpV3 is IVeERC20 {
    function isUserStaking(address _addr) external view returns (bool);

    function deposit(uint256 _amount) external;

    function lockPtp(uint256 _amount, uint256 _lockDays) external returns (uint256);

    function extendLock(uint256 _daysToExtend) external returns (uint256);

    function addPtpToLock(uint256 _amount) external returns (uint256);

    function unlockPtp() external returns (uint256);

    function claim() external;

    function claimable(address _addr) external view returns (uint256);

    function claimableWithXp(address _addr) external view returns (uint256 amount, uint256 xp);

    function withdraw(uint256 _amount) external;

    function vePtpBurnedOnWithdraw(address _addr, uint256 _amount) external view returns (uint256);

    function stakeNft(uint256 _tokenId) external;

    function unstakeNft() external;

    function getStakedNft(address _addr) external view returns (uint256);

    function getStakedPtp(address _addr) external view returns (uint256);

    function levelUp(uint256[] memory platypusBurned) external;

    function levelDown() external;

    function getVotes(address _account) external view returns (uint256);
}
