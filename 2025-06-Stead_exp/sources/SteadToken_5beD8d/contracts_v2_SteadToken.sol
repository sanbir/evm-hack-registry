// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interface/ISteadToken.sol";
import "./Registry.sol";
import "./PricePeg.sol";

contract SteadToken is ISteadToken, ERC20Upgradeable, OwnableUpgradeable {
    // Variables
    mapping(address => bool) public operators;
    mapping(string => address) public acceptedTokens;
    bool public isNativeAccepted;
    uint256 deployTime;
    Registry public registry;
    Token public token;

    // Events
    event SteadSaleMinted(address indexed to, uint256 amount);
    event SteadSaleBurned(address indexed from, uint256 amount);
    event SteadTokenSold(address indexed from, uint256 amount);

    // Modifiers
    modifier onlyOperator() {
        require(
            operators[msg.sender],
            "SteadTokenV2: caller is not the operator"
        );
        _;
    }

    // Constructor
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __ERC20_init("Stead Token", "STEAD");

        _mint(msg.sender, 5_000_000 * 10 ** decimals());
    }

    // Main Functions
    function mint(address _receiver, uint256 _amount) external onlyOperator {
        _mint(_receiver, _amount);
        emit SteadSaleMinted(msg.sender, _amount);
    }

    // Burn Functions
    function burn(address _user, uint256 _amount) external onlyOperator {
        _burn(_user, _amount);
    }

    // Function to set an operator status as true/false
    function setOperator(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
    }

    function setRegistry(Registry _registry) external onlyOwner {
        registry = _registry;
    }

    /**
     * Used every after several months to update base price
     * and avoid gas overflow.
     */

    function updateCurrentPrice() external onlyOwner {
        uint256 currPrice = getCurrentPrice();
        token.basePrice = currPrice;
        token.baseTime = block.timestamp;
    }

    // Read Functions
    function getCurrentPrice() public view returns (uint256) {
        uint256 currPrice = token.basePrice;
        uint256 iteration = (block.timestamp - token.baseTime) / 30 days;

        if (iteration == 0) {
            return currPrice;
        }

        for (uint256 index = 0; index < iteration; index++) {
            currPrice += ((currPrice * 9) / 1000);
        }

        return currPrice;
    }

    // Overrides
    function decimals() public view virtual override returns (uint8) {
        return uint8(6);
    }
}
