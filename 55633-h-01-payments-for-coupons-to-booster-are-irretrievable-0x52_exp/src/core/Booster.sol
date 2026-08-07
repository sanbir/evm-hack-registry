// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.4;

import "../interfaces/Interfaces.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @author Heisenberg
 * @notice Buffer Options Router Contract
 */
contract Booster is Ownable, IBooster, AccessControl {
    using SafeERC20 for ERC20;

    ITraderNFT nftContract;
    uint16 public MAX_TRADES_PER_BOOST = 2;
    uint256 public couponPrice;
    uint256 public boostPercentage;
    bytes32 public constant OPTION_ISSUER_ROLE =
        keccak256("OPTION_ISSUER_ROLE");

    mapping(address => mapping(address => UserBoostTrades))
        public userBoostTrades;
    mapping(uint8 => uint8) public nftTierDiscounts;

    constructor(address _nft) {
        nftContract = ITraderNFT(_nft);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setConfigure(
        uint8[4] calldata _nftTierDiscounts
    ) external onlyOwner {
        for (uint8 i; i < 4; i++) {
            nftTierDiscounts[i] = _nftTierDiscounts[i];
        }
    }

    function getUserBoostData(
        address user,
        address token
    ) external view override returns (UserBoostTrades memory) {
        return userBoostTrades[token][user];
    }

    function updateUserBoost(
        address user,
        address token
    ) external override onlyRole(OPTION_ISSUER_ROLE) {
        UserBoostTrades storage userBoostTrade = userBoostTrades[token][user];
        userBoostTrade.totalBoostTradesUsed += 1;
        emit UpdateBoostTradesUser(user, token);
    }

    function getBoostPercentage(
        address user,
        address token
    ) external view override returns (uint256) {
        UserBoostTrades memory userBoostTrade = userBoostTrades[token][user];
        if (
            userBoostTrade.totalBoostTrades >
            userBoostTrade.totalBoostTradesUsed
        ) {
            return boostPercentage;
        } else return 0;
    }

    function setPrice(uint256 price) external onlyOwner {
        couponPrice = price;
        emit SetPrice(couponPrice);
    }

    function setBoostPercentage(uint256 boost) external onlyOwner {
        boostPercentage = boost;
        emit SetBoostPercentage(boost);
    }

    function buy(address tokenAddress, uint256 traderNFTId) external {
        address user = msg.sender;
        ERC20 token = ERC20(tokenAddress);

        uint256 discount;
        if (nftContract.tokenOwner(traderNFTId) == user)
            discount =
                (couponPrice *
                    nftTierDiscounts[
                        nftContract.tokenTierMappings(traderNFTId)
                    ]) /
                100;
        uint256 price = couponPrice - discount;
        require(token.balanceOf(user) >= price, "Not enough balance");

        token.safeTransferFrom(user, address(this), couponPrice);
        userBoostTrades[tokenAddress][user]
            .totalBoostTrades += MAX_TRADES_PER_BOOST;

        emit BuyCoupon(tokenAddress, user, couponPrice);
    }
}
