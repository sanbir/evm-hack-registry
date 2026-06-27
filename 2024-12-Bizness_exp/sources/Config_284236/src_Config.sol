// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Recoverable.sol";
import "./interfaces/IConfig.sol";

contract Config is IConfig, Recoverable {
    address payable public treasury; /// @dev Treasury
    address public token; /// @dev Token address
    address public babyTokenDividendTrackerFactory;
    address public dividendDistributorFactory;
    uint256 public hodl; /// @dev Platform fee is free when total token hodl amount is greater than or equal to this value
    Fees public fees; /// @dev Platform fees for each tool
    PresaleFees public presaleFees; /// @dev Presale fees for base and quote token

    mapping (address => bool) public whitelist; /// @dev Whitelist user address or token address for fee exemption

    event TreasuryUpdated(address indexed _oldTreasury, address indexed _newTreasury);
    event TokenUpdated(address indexed _oldToken, address indexed _newToken);
    event BabyTokenDividendTrackerFactoryUpdated(address indexed _oldFactory, address indexed _newFactory);
    event DividendDistributorFactoryUpdated(address indexed _oldFactory, address indexed _newFactory);
    event HodlUpdated(uint256 indexed _oldHodl, uint256 indexed _newHodl);
    event FeeUpdated(Tools indexed _tool, uint256 indexed _oldFee, uint256 indexed _newFee);
    event PresaleFeeUpdated(uint256 _oldBaseFee, uint256 indexed _newBaseFee, uint256 _oldQuoteFee, uint256 indexed _newQuoteFee);
    event WhitelistUpdated(address indexed _address, bool _status);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address payable _treasury, address _token, uint256 _hodl) external initializer {
        __Recoverable_init();
        _updateTreasury(_treasury);
        _updateToken(_token);
        _updateHodl(_hodl);
    }

    function updateTreasury(address payable _treasury) external onlyOwner {
        _updateTreasury(_treasury);
    }

    function _updateTreasury(address payable _newTreasury) internal {
        require(_newTreasury != address(0), "Config: zero address");

        address _oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(_oldTreasury, _newTreasury);
    }

    function updateToken(address _token) external onlyOwner {
        _updateToken(_token);
    }

    function _updateToken(address _newToken) internal {
        require(_newToken != address(0), "Config: zero address");

        address _oldToken = token;
        token = _newToken;
        emit TokenUpdated(_oldToken, _newToken);
    }

    function updateBabyTokenDividendTrackerFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Config: zero address");

        address _oldFactory = babyTokenDividendTrackerFactory;
        babyTokenDividendTrackerFactory = _factory;
        emit BabyTokenDividendTrackerFactoryUpdated(_oldFactory, _factory);
    }

    function updateDividendDistributorFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Config: zero address");

        address _oldFactory = dividendDistributorFactory;
        dividendDistributorFactory = _factory;
        emit DividendDistributorFactoryUpdated(_oldFactory, _factory);
    }

    function updateHodl(uint256 _hodl) external onlyOwner {
        _updateHodl(_hodl);
    }

    function _updateHodl(uint256 _newHodl) internal {
        uint256 _oldHodl = hodl;
        hodl = _newHodl;
        emit HodlUpdated(_oldHodl, _newHodl);
    }

    function updateFee(Tools _tool, uint256 _newFee) external onlyOwner {
        uint256 _oldFee;

        if (_tool == Tools.MultiSender) {
            _oldFee = fees.multisender;
            fees.multisender = _newFee;
        } else if (_tool == Tools.Locker) {
            _oldFee = fees.locker;
            fees.locker = _newFee;
        } else if (_tool == Tools.Token) {
            _oldFee = fees.token;
            fees.token = _newFee;
        } else {
            revert("Config: Invalid tool");
        }

        emit FeeUpdated(_tool, _oldFee, _newFee);
    }

    function updatePresaleFee(uint256 _baseFee, uint256 _quoteFee) external onlyOwner {
        uint256 _oldBaseFee = presaleFees.base;
        uint256 _oldQuoteFee = presaleFees.quote;
        presaleFees = PresaleFees(_baseFee, _quoteFee);
        emit PresaleFeeUpdated(_oldBaseFee, _baseFee, _oldQuoteFee, _quoteFee);
    }

    function updateWhitelist(address _address, bool _status) external onlyOwner {
        whitelist[_address] = _status;
        emit WhitelistUpdated(_address, _status);
    }

    fallback() external {
        revert("Config: ETH transfers not allowed");
    }

    function _authorizeUpgrade(address _newImplementation) internal onlyOwner override {}
}
