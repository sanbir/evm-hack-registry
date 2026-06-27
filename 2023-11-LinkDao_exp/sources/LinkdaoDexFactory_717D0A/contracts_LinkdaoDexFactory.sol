// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.20;

import {ILinkdaoDexFactory} from "./interfaces/ILinkdaoDexFactory.sol";
import {ILinkdaoDexPair} from "./interfaces/ILinkdaoDexPair.sol";
import {LinkdaoDexPair} from "./LinkdaoDexPair.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LinkdaoDexFactory is ILinkdaoDexFactory, Ownable {
    bytes32 public constant PAIR_HASH =
        keccak256(type(LinkdaoDexPair).creationCode);

    address public override feeTo;
    address public override feeToSetter;

    uint256 private FEE_PERCENTAGE = 25; // 0.25%

    uint256 private BUY_BACK_LKD_PERCENTAGE = 3000; //30%
    uint256 private TREASURY_PERCENTAGE = 1000; //10%

    uint256 private TOTAL_FEE_PERCENTAGE = 10000; // 100%

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _feeToSetter) Ownable(msg.sender) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function getFeePercentage() external view override returns (uint256) {
        return FEE_PERCENTAGE;
    }

    function getBuyBackLkdPercentage()
        external
        view
        override
        returns (uint256)
    {
        return BUY_BACK_LKD_PERCENTAGE;
    }

    function getTreasuryPercentage() external view override returns (uint256) {
        return TREASURY_PERCENTAGE;
    }

    function getTotalFeePercentage() external view override returns (uint256) {
        return TOTAL_FEE_PERCENTAGE;
    }

    function setFeePercentage(
        uint256 _feePercentage
    ) external override onlyOwner {
        require(
            _feePercentage <= 10000,
            "LinkdaoDex: FEE_PERCENTAGE_SHOULD_BE_LESS_THAN_10000"
        );
        FEE_PERCENTAGE = _feePercentage;
    }

    function setBuyBackLkdPercentage(
        uint256 _buyBackLkdPercentage
    ) external onlyOwner {
        require(
            _buyBackLkdPercentage <= 10000,
            "LinkdaoDex: BUY_BACK_LKD_PERCENTAGE_SHOULD_BE_LESS_THAN_10000"
        );
        BUY_BACK_LKD_PERCENTAGE = _buyBackLkdPercentage;
    }

    function setTreasuryPercentage(
        uint256 _treasuryPercentage
    ) external onlyOwner {
        require(
            _treasuryPercentage <= 10000,
            "LinkdaoDex: TREASURY_PERCENTAGE_SHOULD_BE_LESS_THAN_10000"
        );
        TREASURY_PERCENTAGE = _treasuryPercentage;
    }

    function createPair(
        address tokenA,
        address tokenB
    ) external override returns (address pair) {
        require(tokenA != tokenB, "LinkdaoDex: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "LinkdaoDex: ZERO_ADDRESS");
        require(
            getPair[token0][token1] == address(0),
            "LinkdaoDex: PAIR_EXISTS"
        ); // single check is sufficient

        pair = address(
            new LinkdaoDexPair{
                salt: keccak256(abi.encodePacked(token0, token1))
            }()
        );
        ILinkdaoDexPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "LinkdaoDex: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "LinkdaoDex: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
