// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Base4626Compounder, ERC20, SafeERC20, Math} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {TradeFactorySwapper} from "@periphery/swappers/TradeFactorySwapper.sol";
import {IPool} from "src/interfaces/ICurveInterfaces.sol";
import {IConvexBooster, IConvexRewards} from "src/interfaces/IConvexInterfaces.sol";
import {IAuction} from "src/interfaces/IAuction.sol";

contract StrategyLlamaLendConvex is Base4626Compounder, TradeFactorySwapper {
    using SafeERC20 for ERC20;

    enum SwapType {
        NULL,
        TRICRV,
        AUCTION,
        TF
    }

    /// @notice This is the deposit contract that all Convex pools use, aka booster.
    IConvexBooster public immutable booster;

    /// @notice This is unique to each pool and holds the rewards.
    IConvexRewards public immutable rewardsContract;

    /// @notice This is a unique numerical identifier for each Convex pool.
    uint256 public immutable pid;

    /// @notice Curve gauge address corresponding to our Curve Lend LP
    address public immutable gauge;

    /// @notice Address of the specific Auction this strategy uses.
    address public auction;

    // Mapping to be set by management for any reward tokens.
    // This can be used to set different mins for different tokens
    // or to set to uin256.max if selling a reward token is reverting
    mapping(address => uint256) public minAmountToSellMapping;

    /// @notice Mapping for token address => swap type.
    /// @dev Used to set different swap methods for each reward token.
    mapping(address => SwapType) public swapType;

    /// @notice Minimum amount out in BPS based on oracle pricing. 9900 = 1% slippage allowed
    uint256 public minOutBps = 9900;

    /// @notice All reward tokens sold by this strategy by any method.
    address[] internal allRewardTokens;

    /// @notice Address for TriCRV pool to sell CRV => crvUSD
    IPool internal constant TRICRV =
        IPool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);

    /// @notice CRV token address
    ERC20 internal constant CRV =
        ERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

    /**
     * @param _asset Underlying asset to use for this strategy.
     * @param _name Name to use for this strategy. Ideally something human readable for a UI to use.
     * @param _vault ERC4626 vault token to use. In Curve Lend, these are the base LP tokens.
     * @param _pid PID for our Convex pool.
     * @param _booster Address for Convex's booster.
     */
    constructor(
        address _asset,
        string memory _name,
        address _vault,
        uint256 _pid,
        address _booster
    ) Base4626Compounder(_asset, _name, _vault) {
        // ideally this booster value is pre-filled using a factory (specific to each chain)
        booster = IConvexBooster(_booster);

        // pid is specific to each pool
        pid = _pid;

        // use our pid to pull the corresponding rewards contract and LP token
        (
            address lptoken,
            ,
            address _gauge,
            address _rewardsContract,
            ,

        ) = booster.poolInfo(_pid);
        rewardsContract = IConvexRewards(_rewardsContract);
        gauge = _gauge;

        // make sure we used the correct pid for our llama lend vault
        require(_vault == lptoken, "wrong pid");

        // approve LP deposits on the booster
        ERC20(_vault).forceApprove(_booster, type(uint256).max);
        CRV.forceApprove(address(TRICRV), type(uint256).max);
    }

    /* ========== BASE4626 FUNCTIONS ========== */

    /// @notice Balance of 4626 vault tokens staked in convex
    /// @dev Note that Curve Lend vaults are diluted 1000:1 on deposit
    function balanceOfStake() public view override returns (uint256 stake) {
        stake = rewardsContract.balanceOf(address(this));
    }

    function _stake() internal override {
        // send any loose 4626 vault tokens to convex
        booster.deposit(pid, balanceOfVault(), true);
    }

    function _unStake(uint256 _amount) internal override {
        // _amount is already in 4626 vault shares, no need to convert from asset
        rewardsContract.withdrawAndUnwrap(_amount, false);
    }

    function vaultsMaxWithdraw() public view override returns (uint256) {
        // we use the gauge address here since that's where our convex's voter deposits the LP
        // should be the minimum of what the gauge can redeem (limited by utilization),
        //  and our staked balance + loose vault tokens
        return
            vault.convertToAssets(
                Math.min(
                    vault.maxRedeem(gauge),
                    balanceOfStake() + balanceOfVault()
                )
            );
    }

    // allow keepers to deposit idle profit to curve lend positions as needed
    function _tend(uint256 _totalIdle) internal override {
        _deployFunds(_totalIdle);
    }

    /* ========== TRADE FACTORY & AUCTION FUNCTIONS ========== */

    function claimRewards() external override onlyManagement {
        _claimRewards();
    }

    function _claimRewards() internal override {
        rewardsContract.getReward(address(this), true);
    }

    function _claimAndSellRewards() internal override {
        // claim rewards
        _claimRewards();

        // check for CRV balance to sell atomically
        if (swapType[address(CRV)] == SwapType.TRICRV) {
            uint256 balance = CRV.balanceOf(address(this));
            if (balance > minAmountToSellMapping[address(CRV)]) {
                _swapCrvToStable(balance);
            }
        }
    }

    function _swapCrvToStable(uint256 _amount) internal {
        // atomic swaps should always be sent via private mempool but use price_oracle as backstop
        uint256 crvPrice = TRICRV.price_oracle(1);
        uint256 minAmount = (_amount * crvPrice * minOutBps) / (1e18 * 10_000);
        TRICRV.exchange(2, 0, _amount, minAmount);
    }

    function kickAuction(
        address _token
    ) external onlyKeepers returns (uint256) {
        require(swapType[_token] == SwapType.AUCTION, "!auction");
        return _kickAuction(_token);
    }

    /**
     * @dev Kick an auction for a given token.
     * @param _from The token that was being sold.
     */
    function _kickAuction(address _from) internal virtual returns (uint256) {
        require(
            _from != address(asset) && _from != address(vault),
            "cannot kick"
        );
        uint256 _balance = ERC20(_from).balanceOf(address(this));
        ERC20(_from).safeTransfer(auction, _balance);
        return IAuction(auction).kick(_from);
    }

    function getAllRewardTokens() external view returns (address[] memory) {
        return allRewardTokens;
    }

    function addRewardToken(
        address _token,
        SwapType _swapType
    ) external onlyManagement {
        require(
            _token != address(asset) && _token != address(vault),
            "!allowed"
        );

        // make sure we haven't already set a swap type for this asset
        require(swapType[_token] == SwapType.NULL, "!exists");

        // shouldn't ever add an asset but set to null
        require(_swapType != SwapType.NULL, "!null");

        allRewardTokens.push(_token);
        swapType[_token] = _swapType;

        // enable on our trade factory
        if (_swapType == SwapType.TF) {
            _addToken(_token, address(asset));
        }
    }

    function removeRewardToken(address _token) external onlyManagement {
        address[] memory _allRewardTokens = allRewardTokens;
        uint256 _length = _allRewardTokens.length;
        SwapType _swapType = swapType[_token];

        for (uint256 i; i < _length; ++i) {
            if (_allRewardTokens[i] == _token) {
                allRewardTokens[i] = _allRewardTokens[_length - 1];
                allRewardTokens.pop();
                break;
            }
        }
        delete swapType[_token];
        delete minAmountToSellMapping[_token];

        // disable on our trade factory
        if (_swapType == SwapType.TF) {
            _removeToken(_token, address(asset));
        }
    }

    /* ========== PERMISSIONED SETTER FUNCTIONS ========== */

    /**
     * @notice Use to update our trade factory.
     * @dev Can only be called by management.
     * @param _tradeFactory Address of new trade factory.
     */
    function setTradeFactory(address _tradeFactory) external onlyManagement {
        _setTradeFactory(_tradeFactory, address(asset));
    }

    /**
     * @notice Use to update our auction address.
     * @dev Can only be called by management.
     * @param _auction Address of new auction.
     */
    function setAuction(address _auction) external onlyManagement {
        if (_auction != address(0)) {
            require(IAuction(_auction).want() == address(asset), "wrong want");
            require(
                IAuction(_auction).receiver() == address(this),
                "wrong receiver"
            );
        }
        auction = _auction;
    }

    /**
     * @notice Set the swap type for a specific token.
     * @param _from The address of the token to set the swap type for.
     * @param _swapType The swap type to set.
     */
    function setSwapType(
        address _from,
        SwapType _swapType
    ) external onlyManagement {
        // just remove instead of setting to null, make sure we already set a swap type for this asset
        require(
            _swapType != SwapType.NULL && swapType[_from] != SwapType.NULL,
            "!null"
        );

        if (_swapType == SwapType.TF) {
            _addToken(_from, address(asset));
        } else if (swapType[_from] == SwapType.TF) {
            _removeToken(_from, address(asset));
        }
        swapType[_from] = _swapType;
    }

    /**
     * @notice Set our minOut BPS amount for atomic swaps.
     * @dev For example, 9990 means we allow max of 0.1% deviation in minOut from oracle pricing for swaps.
     * @param _minOutBps The amount of token we expect out in BPS based on pool oracle pricing.
     */
    function setMinOutBps(uint256 _minOutBps) external onlyManagement {
        require(_minOutBps < 10_000, "not bps");
        require(_minOutBps > 9000, "10% max");
        minOutBps = _minOutBps;
    }

    /**
     * @notice Set the `minAmountToSellMapping` for a specific `_token`.
     * @dev This can be used by management to adjust wether or not the
     * _claimAndSellRewards() function will attempt to sell a specific
     * reward token. This can be used if liquidity is to low, amounts
     * are to low or any other reason that may cause reverts.
     *
     * @param _token The address of the token to adjust.
     * @param _amount Min required amount to sell.
     */
    function setMinAmountToSellMapping(
        address _token,
        uint256 _amount
    ) external onlyManagement {
        minAmountToSellMapping[_token] = _amount;
    }
}
