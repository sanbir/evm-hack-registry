// SPDX-License-Identifier: ISC
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title CES_tokenV1 (Upgradeable)
/// @notice ERC20 token with upgrades, ограничением на cap, minter roles,  block/unblock user
contract CES_tokenV1 is Initializable, ERC20Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    uint256 public cap; // max token amount forr mint

    string internal _customName; // Кастомное имя токена (changeble)
    string internal _customSymbol; // custo, symbol

    mapping(address => bool) public blocked; // blocked user's addresses

    //Роль для аккаунтов, которым разрешено минтить токены
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Конструктор вызывает _disableInitializers() для защиты логики UUPS
    constructor() {
        _disableInitializers();
    }

    /// @notice intializing contract instead of constructor (uups)
    /// @param name_ token name
    /// @param symbol_ token symbol
    /// @param cap_ Max supply
    /// @param admin адрес администратора
    function initialize(
        string memory name_, 
        string memory symbol_, 
        uint256 cap_, 
        address admin
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);

        _customName = name_;
        _customSymbol = symbol_;
        
        cap = cap_;
    }

    /// @dev Функция авторизации апгрейда (требуется роль DEFAULT_ADMIN_ROLE)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice геттер имя токена
    function name() public view override returns (string memory) {
        return _customName;
    }

    /// @notice геттер симбол токена
    function symbol() public view override returns (string memory) {
        return _customSymbol;
    }

    /// @notice Модификатор: block action if user on black list
    modifier notBlocked(address account) {
        require(!blocked[account], "CES_token: account is blocked");
        _;
    }

    /// @notice сеттер имя токена
    function setName(string memory newName) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _customName = newName;
    }

    /// @notice сеттер символ токена
    function setSymbol(string memory newSymbol) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _customSymbol = newSymbol;
    }

    /// @notice позволяет админу забрать с контракта случайно присланные токены
    function withdrawStuckTokens(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ERC20Upgradeable(token).transfer(msg.sender, ERC20Upgradeable(token).balanceOf(address(this)));
    }

    /// @notice Минт токенов одному аккаунту (  только MINTER_ROLE)
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) notBlocked(account) {
        require(totalSupply() + amount <= cap, "CES_token: cap exceeded");
        _mint(account, amount);
    }

    /// @notice минт токенов множеству адресов ( только MINTER_ROLE)
    function mintBatch(address[] memory accounts, uint256[] memory amounts) external onlyRole(MINTER_ROLE) {
        uint256 len = accounts.length;
        require(len == amounts.length, "CES_token: length mismatch");

        for (uint256 i = 0; i < len; i++) {
            require(totalSupply() + amounts[i] <= cap, "CES_token: cap exceeded");
            require(!blocked[accounts[i]], "CES_token: account is blocked");
            _mint(accounts[i], amounts[i]);
        }
    }

    /// @notice  пользователь может сжечь свои токены и уменьшить cap
    function burn(uint256 amount) external notBlocked(msg.sender) {
        cap -= amount;
        _burn(msg.sender, amount);
    }

    /// @notice заблокировать пользователя ( только админ)
    function blockUser(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blocked[account] = true;
    }

    /// @notice разблокировать пользователя (  только админ)
    function unblockUser(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blocked[account] = false;
    }

    /// @notice   переопределённый transfer с проверкой блокировки
    function transfer(address recipient, uint256 amount) public override notBlocked(msg.sender) notBlocked(recipient) returns (bool) {
        return super.transfer(recipient, amount);
    }

    /// @notice  переопределённый transfer From с проверкой блокировки
    function transferFrom(address sender, address recipient, uint256 amount) public override notBlocked(sender) notBlocked(recipient) returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    // SET MINTER ROLE
    function setMinterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, account);
    }

    // REMOVE MINTER ROLE
    function removeMinterRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, account);
    }
}