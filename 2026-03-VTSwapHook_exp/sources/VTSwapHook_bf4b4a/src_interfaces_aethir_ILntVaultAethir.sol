// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Constants} from "src/libraries/Constants.sol";

interface ILntVaultAethir is IERC165 {
    event Expired(address account);
    event Unexpired(address account);
    event PauseDeposit(address account);
    event UnpauseDeposit(address account);
    event PauseRedeem(address account);
    event UnpauseRedeem(address account);

    event Deposit(uint256 indexed tokenId, address indexed user);

    event Redeem(uint256 indexed tokenId, address indexed user);

    event SetUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    event RemoveSetUserRecord(uint256 indexed tokenId, bool owned, bool banned, bool forced);

    event UpdateCheckerNode(address indexed previousCheckerNode, address indexed newCheckerNode);

    event UpdateAVTOracle(address indexed previousOracle, address indexed newOracle);

    event UpdateRedeemStrategy(address indexed previousStrategy, address indexed newStrategy);

    event UpdateVTSwapHook(address indexed previousHook, address indexed newHook);

    event UpdateVTPriceTime(uint256 previousStartTime, uint256 newStartTime, uint256 previousEndTime, uint256 newEndTime);

    event VTMinted(address indexed user, uint256 amount);

    event VTBurned(address indexed user, uint256 amount);

    event RedeemT(address indexed user, uint256 amount);

    event WithdrawProfitT(address indexed recipient, uint256 amount);

    event UpdateAutoBuyback(bool previous, bool current);

    event BuybackPoolUninitialized(address indexed VT, address indexed T, address hooks);

    event BuybackQuoteFailed(address indexed VT, address indexed T, address hooks, uint256 amountOutVT);

    event BuybackThresholdNotMet(
        address indexed VT, address indexed T, uint256 threshold, uint256 deltaT, uint256 amountOutVT
    );

    event BuybackSwapFailed(
        address indexed VT, address indexed T, address hooks, uint256 amountInT, uint256 minAmountOutVT
    );

    event Buyback(
        address indexed VT, address indexed T, address hooks,
        uint256 amountA, uint256 amountB, uint256 amountC, uint256 amountD,
        uint256 profitT, uint256 profitCommissionT, uint256 remainingProfitT
    );

    function checkerNode() external view returns (address);

    function NFT() external view returns (address);

    function VT() external view returns (address);

    function T() external view returns (address);

    function vtPriceStartTime() external view returns (uint256);
    function vtPriceEndTime() external view returns (uint256);

    function deposit(uint256 tokenId) external;

    function redeem() external returns (uint256 tokenId);

    function redeemT(uint256 amount) external;

    function expired() external view returns (bool);
    function pausedDeposit() external view returns (bool);
    function pausedRedeem() external view returns (bool);
}
