// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.5;
import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ICommunity {
    function referrerOf(address account) external view returns (address);
}

interface IDAOReward {
    function addReward(address recipient, uint256 amount) external;
}

interface IWebKeyNFT {
    function mint(address to) external;
    function nextTokenId() external view returns (uint256);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract WebKeyProSales is OwnableUpgradeable, AccessControlUpgradeable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct SaleInfo {
        uint256 price;
        uint256 totalTokens;
        uint256 immediateReleaseTokens;
        uint256 available;
        uint256 initialAvailable;
        uint256 timestamp;
        address operator;
    }

    struct BuyerInfo {
        uint256 price;
        uint256 totalTokens;
        uint256 immediateReleased;
        uint256 releasedTokens;
        uint256 releaseCount;
        uint256 tokenId;
    }

    IERC20Upgradeable public usdt;
    address public wkey;
    IWebKeyNFT public nft;
    ICommunity public community;
    IDAOReward public daoReward;
    SaleInfo public currentSaleInfo;
    SaleInfo[] public saleHistory;
    mapping(address => BuyerInfo[]) public buyers;

    uint256 public firstLevelCommission ; // 10%
    uint256 public secondLevelCommission ; // 5%
    uint256 public daoRewardCommission ; // 5%

    function initialize(address usdtAddress, address wkeyAddress,address nftAddress, address communityAddress, address daoRewardAddress) public initializer {
        __Ownable_init();
        __AccessControl_init();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
        usdt = IERC20Upgradeable(usdtAddress);
        wkey = wkeyAddress;
        nft = IWebKeyNFT(nftAddress);
        community = ICommunity(communityAddress);
        daoReward = IDAOReward(daoRewardAddress);
        firstLevelCommission = 10;
        secondLevelCommission = 5;
        daoRewardCommission = 5;
    }

    function setOperator(address operator, bool isOperator) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        if (isOperator) {
            grantRole(OPERATOR_ROLE, operator);
        } else {
            revokeRole(OPERATOR_ROLE, operator);
        }
    }

    function setUsdt(address _usdt) external { 
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        usdt = IERC20Upgradeable(_usdt);
    }

    function setWkey(address _wkey) external { 
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        wkey = _wkey;
    }

    function setSaleInfo(uint256 _available, uint256 _price, uint256 _totalTokens, uint256 _immediateReleaseTokens) external { require(hasRole(OPERATOR_ROLE, msg.sender), "Caller is not an operator");
        require(_available > 0, "Available stock must be greater than zero");
        require(_totalTokens >= _immediateReleaseTokens, "Total tokens must be greater or equal to immediate release tokens");
        if (currentSaleInfo.price != 0) {
            saleHistory.push(currentSaleInfo);
        }
        currentSaleInfo = SaleInfo({
            price: _price,
            totalTokens: _totalTokens,
            immediateReleaseTokens: _immediateReleaseTokens,
            available: _available,
            initialAvailable: _available,
            timestamp: block.timestamp,
            operator: msg.sender
        });
    }

    function setCommission(uint256 _firstLevel, uint256 _secondLevel, uint256 _daoReward) external { 
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        firstLevelCommission = _firstLevel;
        secondLevelCommission = _secondLevel;
        daoRewardCommission = _daoReward;
    }

    function buy() external {
        require(currentSaleInfo.available > 0, "Out of stock");
        require(usdt.transferFrom(msg.sender, address(this), currentSaleInfo.price), "USDT payment failed");

        currentSaleInfo.available -= 1;
        uint256 immediateTokens = currentSaleInfo.immediateReleaseTokens;
        uint256 totalTokens = currentSaleInfo.totalTokens;
        
        console.log("to get nextTokenId");
        uint256 tokenId = nft.nextTokenId();

        console.log("to mint");
        nft.mint(msg.sender);

        buyers[msg.sender].push(BuyerInfo({
            price: currentSaleInfo.price,
            totalTokens: totalTokens,
            immediateReleased: immediateTokens,
            releasedTokens: immediateTokens,
            releaseCount: 1,
            tokenId: tokenId
        }));

        console.log("to transfer immediateTokens");
        if (immediateTokens > 0) {
            console.log("to mint wkey");
            IMintable(wkey).mint(address(this), immediateTokens);
            console.log("to transfer wkey");
            require(IERC20Upgradeable(wkey).transfer(msg.sender, immediateTokens), "WKEY transfer failed");
        }

        
        // Distribute commissions
        address firstReferer = community.referrerOf(msg.sender);
        console.log("firstReferer", firstReferer);

        if (firstReferer != address(0)) {
            uint256 firstCommission = (currentSaleInfo.price * firstLevelCommission) / 100;
            require(usdt.transfer(firstReferer, firstCommission), "First level commission transfer failed");

            address secondReferer = community.referrerOf(firstReferer);
            if (secondReferer != address(0)) {
                uint256 secondCommission = (currentSaleInfo.price * secondLevelCommission) / 100;
                require(usdt.transfer(secondReferer, secondCommission), "Second level commission transfer failed");
            }
        }

        // Distribute DAO reward
        console.log("to distribute dao reward");
        uint256 daoRewardAmount = (currentSaleInfo.price * daoRewardCommission) / 100;
        daoReward.addReward(msg.sender,daoRewardAmount);
    }
}
