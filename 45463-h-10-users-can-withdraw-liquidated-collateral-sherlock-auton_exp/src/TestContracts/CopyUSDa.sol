// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OFTUpgradeable} from "layerzero-v2/oapp/contracts/oft/OFTUpgradeable.sol";

contract TestUSDaStablecoin is
    Initializable,
    OFTUpgradeable,
    UUPSUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable
{
    mapping(address => bool) private whitelist; //!
    address private borrowingContract;
    address private cdsContract;
    uint32 private dstEid;
    address private treasuryContract;
    mapping(address contractAddress => mapping(address spender => uint256))
        public contractAllowances;

    function initialize(
        address _lzEndpoint,
        address _delegate
    ) public initializer {
        __OFT_init("Test Autonomint USD", "TUSDa", _lzEndpoint, _delegate);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    modifier onlyCoreContracts() {
        require(
            (msg.sender == cdsContract) || (msg.sender == borrowingContract),
            "This function can only called by core contracts"
        );
        _;
    }

    modifier onlyTreasury() {
        require(
            (msg.sender == treasuryContract),
            "This function can only called by treasury contract"
        );
        _;
    }

    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

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
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
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
            if (currentAllowance < amount) {
                revert ERC20InsufficientAllowance(
                    msg.sender,
                    currentAllowance,
                    amount
                );
            }
            _contractApprove(from, msg.sender, currentAllowance - amount);
            _transfer(from, to, amount);
            return true;
        } else {
            return false;
        }
    }

    function mint(address to, uint256 amount) public returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burn(uint256 value) public override {
        super.burn(value);
    }

    function burnFrom(address account, uint256 value) public override {
        super.burnFrom(account, value);
    }

    function burnFromUser(address owner, uint256 amount) public returns (bool) {
        burnFrom(owner, amount);
        return true;
    }

    function contractBurnFrom(
        address owner,
        uint256 amount
    ) public returns (bool) {
        uint256 currentAllowance = contractAllowances[owner][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert ERC20InsufficientAllowance(
                    msg.sender,
                    currentAllowance,
                    amount
                );
            }
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
        require(
            _address != address(0) && isContract(_address),
            "Input address is invalid"
        );
        borrowingContract = _address;
    }

    /**
     * @dev set the cds contract
     * @param _address cds contract address
     */
    function setCdsContract(address _address) external onlyOwner {
        require(
            _address != address(0) && isContract(_address),
            "Input address is invalid"
        );
        cdsContract = _address;
    }

    /**
     * @dev set the treasury contract
     * @param _address treasury contract address
     */
    function setTreasuryContract(address _address) external onlyOwner {
        require(
            _address != address(0) && isContract(_address),
            "Input address is invalid"
        );
        treasuryContract = _address;
    }
}
