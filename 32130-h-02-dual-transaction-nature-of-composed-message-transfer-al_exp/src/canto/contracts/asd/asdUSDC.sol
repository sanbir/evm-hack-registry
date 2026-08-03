pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ASDUSDC
 * @notice This contract wraps multiple versions of USDC into one token
 */
contract ASDUSDC is ERC20, Ownable {
    mapping(address => bool) public whitelistedUSDCVersions;
    mapping(address => uint256) public usdcBalances;

    event Deposit(address _version, uint _amount);
    event Withdrawal(address _version, uint _amount);

    constructor() ERC20("ASD USDC", "asdUSDC") {}

    /**
     * @notice Add a USDC version to the whitelist
     * @param _usdcVersion Address of the USDC version to add
     */
    function updateWhitelist(address _usdcVersion, bool _isWhitelisted) external onlyOwner {
        whitelistedUSDCVersions[_usdcVersion] = _isWhitelisted;
    }

    /**
     * @notice Deposit USDC and mint asdUSDC tokens
     * @param _usdcVersion Address of the USDC version to deposit
     * @param _amount Amount of USDC to deposit
     * @return Amount of asdUSDC tokens minted
     */
    function deposit(address _usdcVersion, uint256 _amount) external returns (uint256) {
        // check whitelist
        require(whitelistedUSDCVersions[_usdcVersion], "ASDUSDC: USDC version not whitelisted");
        SafeERC20.safeTransferFrom(ERC20(_usdcVersion), msg.sender, address(this), _amount);
        usdcBalances[_usdcVersion] += _amount;
        // Mint the same amount of asdUSDC tokens but take decimals into account
        uint256 amountToMint = _amount * (10 ** (this.decimals() - ERC20(_usdcVersion).decimals()));
        _mint(msg.sender, amountToMint);
        emit Deposit(_usdcVersion, _amount);
        return amountToMint;
    }

    /**
     * @notice Withdraw USDC and burn asdUSDC tokens
     * @param _usdcVersion Address of the USDC version to withdraw
     * @param _amount Amount of asdUSDC tokens to burn
     * @return Amount of USDC withdrawn
     */
    function withdraw(address _usdcVersion, uint256 _amount) external returns (uint256) {
        // check whitelist
        require(whitelistedUSDCVersions[_usdcVersion], "ASDUSDC: USDC version not whitelisted");
        // burn tokens
        _burn(msg.sender, _amount);
        // calculate amount to withdraw
        uint256 amountToWithdraw = _amount / (10 ** (this.decimals() - ERC20(_usdcVersion).decimals()));
        // check balance
        require(usdcBalances[_usdcVersion] >= amountToWithdraw, "ASDUSDC: Not enough USDC balance");
        // transfer USDC
        usdcBalances[_usdcVersion] -= amountToWithdraw;
        SafeERC20.safeTransfer(ERC20(_usdcVersion), msg.sender, amountToWithdraw);
        emit Withdrawal(_usdcVersion, amountToWithdraw);
        return amountToWithdraw;
    }

    /**
     * @notice Recover any USDC that was sent to the contract by mistake
     * @param _usdcVersion Address of the USDC version to recover
     * @return Amount of USDC minted
     */
    function recover(address _usdcVersion) external onlyOwner returns (uint256) {
        // recover amount
        uint amountToRecover = ERC20(_usdcVersion).balanceOf(address(this)) - usdcBalances[_usdcVersion];
        usdcBalances[_usdcVersion] += amountToRecover;
        // mint tokens
        uint256 amountToMint = amountToRecover * (10 ** (this.decimals() - ERC20(_usdcVersion).decimals()));
        _mint(msg.sender, amountToMint);
        return amountToMint;
    }
}
