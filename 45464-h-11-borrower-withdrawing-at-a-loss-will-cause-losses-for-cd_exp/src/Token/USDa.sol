// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OFTUpgradeable} from "layerzero-v2/oapp/contracts/oft/OFTUpgradeable.sol";

/**
 * @title USDaStablecoin contract
 * @author Autonomint
 * @notice The USDa token contract
 * - has all ERC20 functions and its an OFT
 */

contract USDaStablecoin is
    Initializable,
    OFTUpgradeable,
    UUPSUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable
{
    address private borrowingContract; // borrowing contract address
    address private cdsContract; // cds contract address
    uint32 private dstEid; // Layer zero destination endpoint ID
    address private borrowLiqAddress; // Borrow Liquidation contract address
    address private treasuryContract;
    mapping(address contractAddress => mapping(address spender => uint256)) public contractAllowances;

    /**
     * @dev initialize function to initialize the contract
     * @param _lzEndpoint Layer zero endpoint address
     * @param _delegate owner address
     */
    function initialize(
        address _lzEndpoint,
        address _delegate
    ) public initializer {
        // Initialize the OFt
        __OFT_init("Autonomint USD", "USDa", _lzEndpoint, _delegate);
        // Initialize the token as burnable
        __ERC20Burnable_init();
        // Initialize the token as pausable
        __ERC20Pausable_init();
        // Initialize the owner of the contract
        __Ownable_init(msg.sender);
        // Initialize the proxy
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the msg.sender is one the core contract
     */
    modifier onlyCoreContracts() {
        require(
            (msg.sender == cdsContract) ||
            (msg.sender == borrowingContract) ||
            (msg.sender == borrowLiqAddress),
            "This function can only called by core contracts"
        );
        _;
    }

    modifier onlyTreasury() {
        require( msg.sender == treasuryContract,"This function can only called by treasury contract");
        _;
    }

    /**
     * @dev Function to check if an address is a contract
     * @param account address to check whether the address is an contract address or EOA
     */
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /**
     * @dev sets the destination EID, can only be called by owner
     * @param _eid Endpoint id to assign
     */
    function setDstEid(uint32 _eid) external onlyOwner {
        require(_eid != 0, "EID can't be zero");
        dstEid = _eid;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function mint(
        address to,
        uint256 amount
    ) public onlyCoreContracts returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burn(uint256 value) public override onlyCoreContracts {
        super.burn(value);
    }

    function burnFrom(
        address account,
        uint256 value
    ) public override onlyCoreContracts {
        super.burnFrom(account, value);
    }

    function contractApprove(
        address spender,
        uint256 value
    ) public onlyTreasury returns (bool) {
        return _contractApprove(msg.sender, spender, value);
    }

    function _contractApprove(
        address owner,
        address spender,
        uint256 value
    ) internal returns (bool) {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        contractAllowances[owner][spender] = value;
        emit Approval(owner, spender, value);
        return true;
    }

    function contractTransferFrom(
        address from,
        address to,
        uint256 amount
    ) public onlyCoreContracts returns (bool) {
        uint256 currentAllowance = contractAllowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert ERC20InsufficientAllowance(msg.sender, currentAllowance, amount);
            _contractApprove(from, msg.sender, currentAllowance - amount);
            _transfer(from, to, amount);
            return true;
        } else {
            return false;
        }
    }

    function burnFromUser(
        address to,
        uint256 amount
    ) public onlyCoreContracts returns (bool) {
        burnFrom(to, amount);
        return true;
    }

    function contractBurnFrom(
        address owner,
        uint256 amount
    ) public returns (bool) {
        uint256 currentAllowance = contractAllowances[owner][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert ERC20InsufficientAllowance(msg.sender, currentAllowance, amount);
            _contractApprove(owner, msg.sender, currentAllowance - amount);
            _burn(owner, amount);
            return true;
        } else {
            return false;
        }
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, value);
    }

    /**
     * @dev set the borrowing contract
     * @param _address Borrowing contract address
     */
    function setBorrowingContract(address _address) external onlyOwner {
        require(_address != address(0) && isContract(_address),"Input address is invalid");
        borrowingContract = _address;
    }

    /**
     * @dev Sets the borrow liquidaton contract address, can only be called by owner
     * @param _address Borrow Liquidation contract address
     */
    function setBorrowLiqContract(address _address) external onlyOwner {
        require(_address != address(0) && isContract(_address),"Input address is invalid");
        borrowLiqAddress = _address;
    }

    /**
     * @dev set the cds contract
     * @param _address cds contract address
     */
    function setCdsContract(address _address) external onlyOwner {
        require(_address != address(0) && isContract(_address),"Input address is invalid");
        cdsContract = _address;
    }

    /**
     * @dev set the treasury contract
     * @param _address treasury contract address
     */
    function setTreasuryContract(address _address) external onlyOwner {
        require(_address != address(0) && isContract(_address),"Input address is invalid");
        treasuryContract = _address;
    }
}
