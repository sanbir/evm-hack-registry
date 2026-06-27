pragma solidity 0.8.20;

import {IOneClickProxy} from "../../interfaces/oneClick/IOneClickProxy.sol";
import {IMarginAccountManager} from "../../interfaces/IMarginAccountManager.sol";
import {IMarginTrading} from "../../interfaces/IMarginTrading.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MarginTradingRouter is AccessControl {
    IOneClickProxy public oneClickProxy;
    IMarginAccountManager public immutable marginAccountManager;
    IMarginTrading public immutable marginTrading;
    uint public yellowCoeff = 1.10 * 1e5; 

    mapping(address => bool) public provideWithdrawRestricted;

    constructor(
        address _marginAccountManager,
        address _marginTrading
    ) {
        marginAccountManager = IMarginAccountManager(_marginAccountManager);
        marginTrading = IMarginTrading(_marginTrading);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Modifier to check if the caller is approved or the owner of the margin account.
     * @param marginAccountID The ID of the margin account.
     */
    modifier onlyApprovedOrOwner(uint marginAccountID) {
        require(marginAccountManager.isApprovedOrOwner(msg.sender, marginAccountID), "You are not the owner of the token");
        _;
    }

    modifier onlyNotRestricted(address token) {
        require(provideWithdrawRestricted[token] == false, "Provide or withdraw is restricted");
        _;
    }

    // DEFAULT_ADMIN_ROLE FUNCTIONS

    function approveERC20(address token, address to, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).approve(to, amount);
    }

    function approveERC721ForAll(address token, address to, bool value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC721(token).setApprovalForAll(to, value);
    }

    function setOneClickProxy(IOneClickProxy newOneClickProxy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oneClickProxy = newOneClickProxy;
    }

    function setYellowCoeff(uint newYellowCoeff) external onlyRole(DEFAULT_ADMIN_ROLE) {
        yellowCoeff = newYellowCoeff;
    }

    function setProvideWithdrawRestricted(address token, bool value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        provideWithdrawRestricted[token] = value;
    }

    // ONLY marginAccountID APPROVE OR OWNER FUNCTIONS

    function provideERC20(uint marginAccountID, address token, uint amount) external onlyApprovedOrOwner(marginAccountID) onlyNotRestricted(token) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        oneClickProxy.provideERC20(marginAccountID, token, amount);
    }

    function provideERC721(uint marginAccountID, address token, uint collateralTokenID) external onlyApprovedOrOwner(marginAccountID) onlyNotRestricted(token) {
        IERC721(token).transferFrom(msg.sender, address(this), collateralTokenID);
        oneClickProxy.provideERC721(marginAccountID, token, collateralTokenID);
    }
    
    function withdrawERC20(uint marginAccountID, address token, uint amount) external onlyApprovedOrOwner(marginAccountID) onlyNotRestricted(token) {
        uint marginAccountRatio = marginTrading.getMarginAccountRatio(marginAccountID);
        require(marginAccountRatio >= yellowCoeff, "portfolioRatio is too low"); 
        oneClickProxy.withdrawERC20(marginAccountID, token, amount);
        IERC20(token).transfer(msg.sender, amount);
    }

    function withdrawERC721(uint marginAccountID, address token, uint value) external onlyApprovedOrOwner(marginAccountID) onlyNotRestricted(token) {
        uint marginAccountRatio = marginTrading.getMarginAccountRatio(marginAccountID);
        require(marginAccountRatio >= yellowCoeff, "portfolioRatio is too low"); 
        oneClickProxy.withdrawERC721(marginAccountID, token, value);
        IERC721(token).transferFrom(address(this), msg.sender, value);
    }
    
    function borrow(uint marginAccountID, address token, uint amount) external onlyApprovedOrOwner(marginAccountID) {
        uint marginAccountRatio = marginTrading.getMarginAccountRatio(marginAccountID);
        require(marginAccountRatio >= yellowCoeff, "portfolioRatio is too low"); 
        oneClickProxy.borrow(marginAccountID, token, amount);
    }

    function repay(uint marginAccountID, address token, uint amount) external onlyApprovedOrOwner(marginAccountID) {
        oneClickProxy.repay(marginAccountID, token, amount);
    }
    
    function swap(uint marginAccountID, address tokenIn, address tokenOut, uint amountIn, uint amountOutMinimum) external onlyApprovedOrOwner(marginAccountID) {
        oneClickProxy.swap(marginAccountID, tokenIn, tokenOut, amountIn, amountOutMinimum);
    }

    function exercise(uint marginAccountID, address token, uint collateralTokenID) external onlyApprovedOrOwner(marginAccountID) {
        oneClickProxy.exercise(marginAccountID, token, collateralTokenID);
    }
}