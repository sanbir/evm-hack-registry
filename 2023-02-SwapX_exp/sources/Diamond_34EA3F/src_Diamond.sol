// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./ERC20/ERC20Custom.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IDiamond.sol";
import "./Operator.sol";

contract Diamond is ERC20Custom, Operator, IDiamond {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // ERC20 - Token
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;

    // CONTRACTS
    address public treasury;

    // FLAGS
    bool public initialized;

    // DISTRIBUTION
    uint256 public constant COMMUNITY_ALLOCATION = 7000 ether; // 7K
    uint256 public constant TREASURY_ALLOCATION = 2000 ether; // 2K
    uint256 public constant IRON_ALLOCATION = 1000 ether; // 2K

    uint256 public constant VESTING_DURATION = 730 days; // 24 months

    uint256 public startTime; // Start time of vesting duration
    uint256 public endTime; // End of vesting duration

    address public treasuryFund;
    uint256 public treasuryFundLastClaimed;
    uint256 public constant treasuryFundEmissionRate = TREASURY_ALLOCATION / VESTING_DURATION;

    address public ironFund;
    uint256 public ironFundLastClaimed;
    uint256 public constant ironFundEmissionRate = IRON_ALLOCATION / VESTING_DURATION;

    address public communityFundController; // Holding SHARE tokens to distribute into Liquiditiy Mining Pools
    uint256 public communityFundClaimed;

    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
        require(ITreasury(treasury).isPool(msg.sender), "!pools");
        _;
    }

    modifier checkInitialized() {
        require(initialized, "not initialized");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _treasury
    ) {
        name = _name;
        symbol = _symbol;
        treasury = _treasury;
    }

    function initialize(
        address _treasuryFund,
        address _ironFund,
        address _communityFundController,
        uint256 _startTime
    ) external onlyOperator {
        require(!initialized, "alreadyInitialized");
        require(_treasuryFund != address(0), "invalid_address");
        require(_ironFund != address(0), "invalid_address");
        require(_communityFundController != address(0), "invalid_address");

        initialized = true;
        communityFundController = _communityFundController;
        startTime = _startTime;
        endTime = _startTime + VESTING_DURATION;

        treasuryFund = _treasuryFund;
        treasuryFundLastClaimed = _startTime;

        ironFund = _ironFund;
        ironFundLastClaimed = _startTime;
    }

    /* ========== VIEWS FUNCTIONS =============== */

    function unclaimedTreasuryFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (treasuryFundLastClaimed >= _now) return 0;
        _pending = _now.sub(treasuryFundLastClaimed).mul(treasuryFundEmissionRate);
    }

    function unclaimedIronFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (ironFundLastClaimed >= _now) return 0;
        _pending = _now.sub(ironFundLastClaimed).mul(ironFundEmissionRate);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setTreasury(address _treasury) external onlyOperator {
        treasury = _treasury;
        emit TreasuryChanged(treasury);
    }

    function setTreasuryFund(address _treasuryFund) external {
        require(msg.sender == treasuryFund, "!treasuryFund");
        require(_treasuryFund != address(0), "zero");
        treasuryFund = _treasuryFund;
        emit TreasuryFundChanged(treasuryFund);
    }

    function setIronFund(address _ironFund) external {
        require(msg.sender == ironFund, "!ironFund");
        require(_ironFund != address(0), "zero");
        ironFund = _ironFund;
        emit IronFundChanged(ironFund);
    }

    function setCommunityFundController(address _communityFundController) external {
        require(msg.sender == communityFundController, "!communityFundController");
        require(_communityFundController != address(0), "zero");
        communityFundController = _communityFundController;
        emit CommunityFundControllerChanged(communityFundController);
    }

    function claimCommunityFund(uint256 amount) external onlyOperator checkInitialized {
        require(amount > 0, "invalidAmount");
        require(initialized, "!initialized");
        require(communityFundController != address(0), "!communityFundController");
        uint256 _remainingFund = COMMUNITY_ALLOCATION.sub(communityFundClaimed);
        require(amount <= _remainingFund, "exceeded_community_fund");
        communityFundClaimed = communityFundClaimed.add(amount);
        _mint(communityFundController, amount);
    }

    function claimTreasuryFund() external checkInitialized {
        require(msg.sender == treasuryFund, "!treasuryFund");
        uint256 _pending = unclaimedTreasuryFund();
        if (_pending > 0 && treasuryFund != address(0)) {
            _mint(treasuryFund, _pending);
            treasuryFundLastClaimed = block.timestamp;
        }
    }

    function claimIronFund() external checkInitialized {
        require(msg.sender == ironFund, "!ironFund");
        uint256 _pending = unclaimedIronFund();
        if (_pending > 0 && ironFund != address(0)) {
            _mint(ironFund, _pending);
            ironFundLastClaimed = block.timestamp;
        }
    }

    /* ========== POOL FUNCTIONS ================== */

    // This function is what other Pools will call to mint new SHARE
    function poolMint(address m_address, uint256 m_amount) external override onlyPools {
        super._mint(m_address, m_amount);
        emit DiamondMinted(address(this), m_address, m_amount);
    }

    // This function is what other pools will call to burn SHARE
    function poolBurnFrom(address b_address, uint256 b_amount) external override onlyPools {
        super._burnFrom(b_address, b_amount);
        emit DiamondBurned(b_address, address(this), b_amount);
    }

    /* ========== EVENTS ========== */

    event DiamondMinted(address indexed from, address indexed to, uint256 amount);
    event DiamondBurned(address indexed from, address indexed to, uint256 amount);
    event TreasuryChanged(address indexed newTreasury);
    event TreasuryFundChanged(address indexed newTreasuryFund);
    event IronFundChanged(address indexed newIronFund);
    event CommunityFundControllerChanged(address indexed newCommunityFundController);
}
