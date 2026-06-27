// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface ICvg is IERC20Metadata {
    function MAX_AIRDROP() external view returns (uint256);

    function MAX_BOND() external view returns (uint256);

    function MAX_STAKING() external view returns (uint256);

    function MAX_VESTING() external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function burn(uint256 amount) external;

    function cvgControlTower() external view returns (address);

    function decimals() external view returns (uint8);

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);

    function mintBond(address account, uint256 amount) external;

    function mintStaking(address account, uint256 amount) external;

    function mintedBond() external view returns (uint256);

    function mintedStaking() external view returns (uint256);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
