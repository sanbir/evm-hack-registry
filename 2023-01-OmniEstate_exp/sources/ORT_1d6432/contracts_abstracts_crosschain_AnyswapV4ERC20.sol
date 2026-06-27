// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../ERC2612.sol";
import "../ERC677.sol";
import "../../interfaces/crosschain/IAnyswapV4ERC20.sol";

abstract contract AnyswapV4ERC20 is IAnyswapV4ERC20, ERC2612, ERC677, Ownable {
    using SafeERC20 for IERC20;

    uint8 private _decimals = 18;
    address public override immutable underlying;

    // init flag for setting immediate vault, needed for CREATE2 support
    bool private _init;

    // flag to enable/disable swapout vs vault.burn so multiple events are triggered
    bool private _vaultOnly;

    // delay for timelock functions
    uint256 public override delay = 24*3600;

    // set of minters, can be this bridge or other bridges
    mapping(address => bool) override public isMinter;
    address[] public minters;

    // primary controller of the token contract
    address public override vault;

    address public override pendingMinter;
    uint256 public override delayMinter;

    address public override pendingVault;
    uint256 public override delayVault;

    constructor(string memory _name, string memory _symbol, uint8 _tokendecimals, address _underlying, address _vault)
    ERC2612(_name, _symbol) {
        underlying = _underlying;

        _decimals = _tokendecimals;
        if (_underlying != address(0x0)) {
            require(_decimals == ERC20(_underlying).decimals());
        }

        // Use init to allow for CREATE2 accross all chains
        _init = true;

        // Disable/Enable swapout for v1 tokens vs mint/burn for v3 tokens
        _vaultOnly = false;

        vault = _vault;
        pendingVault = _vault;
        delayVault = block.timestamp;
    }

    modifier onlyMinter() {
        require(isMinter[msg.sender], "AnyswapV4ERC20: FORBIDDEN");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == mpc(), "AnyswapV3ERC20: FORBIDDEN");
        _;
    }

    modifier onlyOwnerOrVault() {
        require(msg.sender == mpc() || msg.sender == owner(), "AnyswapV3ERC20: FORBIDDEN");
        _;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mpc() public virtual override view returns (address) {
        if (block.timestamp >= delayVault) {
            return pendingVault;
        }
        return vault;
    }

    function setVaultOnly(bool enabled) external virtual override onlyOwnerOrVault {
        _vaultOnly = enabled;
    }

    function initVault(address _vault) external virtual override onlyOwnerOrVault {
        require(_init, "AnyswapV4ERC20: ALREADY_INITIALIZED");
        vault = _vault;
        pendingVault = _vault;
        isMinter[_vault] = true;
        minters.push(_vault);
        delayVault = block.timestamp;
        _init = false;
    }

    function setMinter(address _minter) external virtual override onlyOwnerOrVault {
        pendingMinter = _minter;
        delayMinter = block.timestamp + delay;
    }

    function setVault(address _vault) external virtual override onlyOwnerOrVault {
        pendingVault = _vault;
        delayVault = block.timestamp + delay;
    }

    function applyVault() external virtual override onlyOwnerOrVault {
        require(block.timestamp >= delayVault);
        vault = pendingVault;
    }

    function applyMinter() external virtual override onlyOwnerOrVault {
        require(block.timestamp >= delayMinter);
        isMinter[pendingMinter] = true;
        minters.push(pendingMinter);
    }

    // No time delay revoke minter emergency function
    function revokeMinter(address _auth) external virtual override onlyOwnerOrVault {
        isMinter[_auth] = false;
        if (pendingMinter == _auth) {
            pendingMinter = address(0);
        }
    }

    function getAllMinters() external virtual override view returns (address[] memory) {
        return minters;
    }


    function changeVault(address newVault) external virtual override onlyOwnerOrVault returns (bool) {
        require(newVault != address(0), "AnyswapV3ERC20: address(0x0)");
        pendingVault = newVault;
        delayVault = block.timestamp + delay;
        emit LogChangeVault(vault, pendingVault, delayVault);
        return true;
    }

    function changeMPCOwner(address newVault) public virtual override onlyOwnerOrVault returns (bool) {
        require(newVault != address(0), "AnyswapV3ERC20: address(0x0)");
        pendingVault = newVault;
        delayVault = block.timestamp + delay;
        emit LogChangeMPCOwner(vault, pendingVault, delayVault);
        return true;
    }

    function mint(address to, uint256 amount) external virtual override onlyMinter returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burn(address from, uint256 amount) external virtual override onlyMinter returns (bool) {
        require(from != address(0), "AnyswapV3ERC20: address(0x0)");
        _burn(from, amount);
        return true;
    }

    function Swapin(bytes32 txhash, address account, uint256 amount) public virtual override onlyMinter returns (bool) {
        _mint(account, amount);
        emit LogSwapin(txhash, account, amount);
        return true;
    }

    function Swapout(uint256 amount, address bindaddr) public virtual override returns (bool) {
        require(!_vaultOnly, "AnyswapV4ERC20: onlyMinter");
        require(bindaddr != address(0), "AnyswapV3ERC20: address(0x0)");
        _burn(msg.sender, amount);
        emit LogSwapout(msg.sender, bindaddr, amount);
        return true;
    }


    function depositWithPermit(
        address target,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s, address to
    ) external virtual override returns (uint) {
        ERC2612(underlying).permit(target, address(this), value, deadline, v, r, s);
        IERC20(underlying).safeTransferFrom(target, address(this), value);
        return _deposit(value, to);
    }

    function depositWithTransferPermit(
        address target,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s, 
        address to
    ) external virtual override returns (uint) {
        ERC2612(underlying).transferWithPermit(target, address(this), value, deadline, v, r, s);
        return _deposit(value, to);
    }
    
    function deposit() external virtual override returns (uint) {
        uint256 _amount = IERC20(underlying).balanceOf(msg.sender);
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), _amount);
        return _deposit(_amount, msg.sender);
    }

    function deposit(uint256 amount) external virtual override returns (uint) {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        return _deposit(amount, msg.sender);
    }

    function deposit(uint256 amount, address to) external virtual override returns (uint) {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        return _deposit(amount, to);
    }

    function depositVault(uint256 amount, address to) external virtual override onlyVault returns (uint) {
        return _deposit(amount, to);
    }

    function _deposit(uint256 amount, address to) internal returns (uint) {
        require(underlying != address(0x0) && underlying != address(this));
        _mint(to, amount);
        return amount;
    }

    function withdraw() external virtual override returns (uint) {
        return _withdraw(msg.sender, balanceOf(msg.sender), msg.sender);
    }

    function withdraw(uint256 amount) external virtual override returns (uint) {
        return _withdraw(msg.sender, amount, msg.sender);
    }

    function withdraw(uint256 amount, address to) external virtual override returns (uint) {
        return _withdraw(msg.sender, amount, to);
    }

    function withdrawVault(address from, uint256 amount, address to) 
    external virtual override onlyVault returns (uint) {
        return _withdraw(from, amount, to);
    }

    function _withdraw(address from, uint256 amount, address to) internal returns (uint) {
        _burn(from, amount);
        IERC20(underlying).safeTransfer(to, amount);
        return amount;
    }
}