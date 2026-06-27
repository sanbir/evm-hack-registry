pragma solidity 0.8.20;

import {IMarginAccountManager} from "../../interfaces/IMarginAccountManager.sol";
import {IFacadeTradeRouter} from "../../interfaces/oneClick/IFacadeTradeRouter.sol";
import {ITradeRouterEventsStorage} from "../../interfaces/oneClick/ITradeRouterEventsStorage.sol";
import {FacadeTradeRouter} from "../facades/FacadeTradeRouter.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract TradeRouter is AccessControl {

    IMarginAccountManager public marginAccountManager;
    FacadeTradeRouter public facadeTradeRouter;
    ITradeRouterEventsStorage public tradeRouterEventsStorage;

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyApprovedOrOwner(uint marginAccountID) {
        require(marginAccountManager.isApprovedOrOwner(msg.sender, marginAccountID), "You are not the owner of the token");
        _;
    }

    function setMarginAccountManager(address _marginAccountManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        marginAccountManager = IMarginAccountManager(_marginAccountManager);
    }

    function setFacadeTradeRouter(address _facadeTradeRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        facadeTradeRouter = FacadeTradeRouter(_facadeTradeRouter);
    }

    function setTradeRouterEventsStorage(address _tradeRouterEventsStogare) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tradeRouterEventsStorage = ITradeRouterEventsStorage(_tradeRouterEventsStogare);
    }

    function increaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyApprovedOrOwner(marginAccountID) {
        facadeTradeRouter.increaseLongPosition(marginAccountID, token, amount);
        tradeRouterEventsStorage.emitIncreaseLongPosition(marginAccountID, token, amount);
    }

    function increaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyApprovedOrOwner(marginAccountID) {
        facadeTradeRouter.increaseShortPosition(marginAccountID, token, amount);
        tradeRouterEventsStorage.emitIncreaseShortPosition(marginAccountID, token, amount);
    }

    function decreaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyApprovedOrOwner(marginAccountID) {
        facadeTradeRouter.decreaseLongPosition(marginAccountID, token, amount);
        tradeRouterEventsStorage.emitDecreaseLongPosition(marginAccountID, token, amount);
    }

    function decreaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyApprovedOrOwner(marginAccountID) {
        facadeTradeRouter.decreaseShortPosition(marginAccountID, token, amount);
        tradeRouterEventsStorage.emitDecreaseShortPosition(marginAccountID, token, amount);
    }

    function settlePositions(
        uint marginAccountID
    ) external onlyApprovedOrOwner(marginAccountID) {
        facadeTradeRouter.settlePositions(marginAccountID);
        tradeRouterEventsStorage.emitSettlePositions(marginAccountID);
    }
}