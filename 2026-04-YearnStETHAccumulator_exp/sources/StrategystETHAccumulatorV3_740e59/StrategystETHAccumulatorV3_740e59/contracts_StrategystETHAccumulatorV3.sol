// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import {BaseStrategy, StrategyParams} from "contracts/BaseStrategy.sol";
import {Math} from "contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "contracts/token/ERC20/utils/SafeERC20.sol";

import {ISteth, IQueue, IWETH, ICurveFi} from "contracts/interfaces/StethInterfaces.sol";

contract StrategystETHAccumulatorV3 is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Maximum size of stETH or WETH we'll swap at once during harvests
    uint256 public maxSingleTrade;

    /// @notice Max slippage we allow on swaps from stETH to ETH, in bps. 50 = 0.5%.
    uint256 public slippageProtectionOut;

    /// @notice Whether or not we allow losses to be reported.
    /// @dev Useful when scaling up since we discount stETH holdings by peg value. Defaults to true.
    bool public reportLoss = true;

    /// @notice Whether we prevent conversion of more WETH to stETH
    bool public dontInvest = true;

    /// @notice Value to discount our stETH holdings by, in bps.
    uint256 public peg = 95; // 100 = 1%

    /// @notice Value (in wei) of our pending stETH to ETH redemptions
    uint256 public pendingRedemptions;
    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1); // stETH withdrawal queue
    address internal constant WETH_1 =
        0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0;

    ICurveFi public constant StableSwapSTETH =
        ICurveFi(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IWETH public constant weth =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ISteth public constant stETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    uint256 public constant DENOMINATOR = 10_000;
    address internal constant REFERRAL =
        0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; //stratms. for recycling and redepositing

    // stETH specific constants
    int128 internal constant WETHID = 0;
    int128 internal constant STETHID = 1;

    constructor(address _vault) BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 1 weeks;
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // hardcode healthcheck

        IERC20(address(stETH)).forceApprove(
            address(StableSwapSTETH),
            type(uint256).max
        );

        maxSingleTrade = 500 * 1e18;
        slippageProtectionOut = 50;
    }

    //we get eth
    receive() external payable {}

    function updateMaxSingleTrade(uint256 _maxSingleTrade)
        external
        onlyVaultManagers
    {
        maxSingleTrade = _maxSingleTrade;
    }

    function updatePeg(uint256 _peg) external onlyVaultManagers {
        require(_peg <= 1_000); // max 10%
        peg = _peg;
    }

    function updateReportLoss(bool _reportLoss) external onlyVaultManagers {
        reportLoss = _reportLoss;
    }

    function updateDontInvest(bool _dontInvest) external onlyVaultManagers {
        dontInvest = _dontInvest;
    }

    function updateSlippageProtectionOut(uint256 _slippageProtectionOut)
        external
        onlyVaultManagers
    {
        require(_slippageProtectionOut <= 10_000);
        slippageProtectionOut = _slippageProtectionOut;
    }

    function invest(uint256 _amount) external onlyEmergencyAuthorized {
        _invest(_amount);
    }

    //should never have stuck eth but just incase
    function rescueStuckEth() external onlyEmergencyAuthorized {
        weth.deposit{value: address(this).balance}();
    }

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategystETHAccumulator_v3";
    }

    // We hard code a peg here. This is so that we can build up a reserve of profit to cover peg volatility if we are forced to delever
    // This may sound scary but it is the equivalent of using virtualprice in a curve lp. As we have seen from many exploits, virtual pricing is safer than touch pricing.
    function estimatedTotalAssets() public view override returns (uint256) {
        return
            ((stethBalance() * (DENOMINATOR - peg)) / DENOMINATOR) +
            wantBalance();
    }

    function estimatedPotentialTotalAssets() public view returns (uint256) {
        return stethBalance() + wantBalance();
    }

    function wantBalance() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function stethBalance() public view returns (uint256) {
        return stETH.balanceOf(address(this));
    }

    /// @notice Check if our strategy has any pending stETH withdrawals via Lido's withdrawal queue.
    function pendingWithdrawalRequests()
        external
        view
        returns (uint256[] memory requestIds)
    {
        return WITHDRAWAL_QUEUE.getWithdrawalRequests(address(this));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 wantBal = wantBalance();
        uint256 totalAssets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (totalAssets >= debt) {
            _profit = totalAssets - debt;

            uint256 needed = _profit + _debtOutstanding;

            if (needed > wantBal) {
                // reduce amount to withdraw by what we already have
                uint256 toWithdraw = needed - wantBal;

                // we step our withdrawals. adjust max single trade to withdraw more
                toWithdraw = Math.min(maxSingleTrade, toWithdraw);

                // withdraw some extra buffer for swap slippage
                toWithdraw =
                    (toWithdraw * (10_000 + slippageProtectionOut)) /
                    10_000;

                // shouldn't see losses here as we limit swap slippage and have peg buffer
                _divest(toWithdraw);

                // check in on our new amount of tokens after withdrawing
                wantBal = wantBalance();
                totalAssets = estimatedTotalAssets();
            }

            // profit + _debtOutstanding must be <= wantbalance. Prioritise profit first
            if (wantBal < _profit) {
                _profit = wantBal;
            } else if (wantBal < needed) {
                _debtPayment = wantBal - _profit;
            } else {
                _debtPayment = _debtOutstanding;
            }
        } else {
            if (reportLoss) {
                _loss = debt - totalAssets;
            }
        }

        // don't take any losses while we've got pending withdrawals
        if (pendingRedemptions > 0) {
            _loss = 0;
        }
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        _divest(stethBalance());
        _amountFreed = wantBalance();
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (dontInvest) {
            return;
        }
        _invest(wantBalance());
    }

    function _invest(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        _amount = Math.min(maxSingleTrade, _amount);
        uint256 before = stethBalance();

        weth.withdraw(_amount);

        // test if we should buy instead of mint
        uint256 out = StableSwapSTETH.get_dy(WETHID, STETHID, _amount);
        if (out < _amount) {
            stETH.submit{value: _amount}(REFERRAL);
        } else {
            StableSwapSTETH.exchange{value: _amount}(
                WETHID,
                STETHID,
                _amount,
                _amount
            );
        }
    }

    /// @notice Use to manually unwind stETH to WETH via Curve outside of a harvest.
    function manualDivest(uint256 _amount)
        external
        onlyEmergencyAuthorized
        returns (uint256)
    {
        // we step our withdrawals. adjust max single trade to withdraw more
        _amount = Math.min(maxSingleTrade, _amount);

        return _divest(_amount);
    }

    function _divest(uint256 _amount) internal returns (uint256) {
        uint256 before = wantBalance();

        // limit our swap at the size of our total balance
        _amount = Math.min(_amount, stethBalance());

        if (_amount > 0) {
            uint256 slippageAllowance = (_amount *
                (DENOMINATOR - slippageProtectionOut)) / DENOMINATOR;
            StableSwapSTETH.exchange(
                STETHID,
                WETHID,
                _amount,
                slippageAllowance
            );

            weth.deposit{value: address(this).balance}();
        }

        return wantBalance() - before;
    }

    // we attempt to withdraw the full amount and let the user decide if they take the loss or not
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = wantBalance();
        if (wantBal < _amountNeeded) {
            uint256 toWithdraw = _amountNeeded - wantBal;
            uint256 withdrawn = _divest(toWithdraw);
            if (withdrawn < toWithdraw) {
                _loss = toWithdraw - withdrawn;
            }
        }

        _liquidatedAmount = _amountNeeded - _loss;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 stethBal = stethBalance();
        if (stethBal > 0) {
            IERC20(address(stETH)).safeTransfer(_newStrategy, stethBal);
        }
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return nftId Withdrawal ID number from the withdrawal request
    function initiateLSTWithdrawal(uint256 _amount)
        external
        onlyEmergencyAuthorized
        returns (uint256 nftId)
    {
        _amount = Math.min(_amount, stethBalance());
        require(
            _amount > WITHDRAWAL_QUEUE.MIN_STETH_WITHDRAWAL_AMOUNT(),
            "!minimum"
        ); // minimum amount to withdraw
        require(
            _amount <= WITHDRAWAL_QUEUE.MAX_STETH_WITHDRAWAL_AMOUNT(),
            "!maximum"
        ); // maximum amount to withdraw in one request

        pendingRedemptions += _amount;

        return _initiateLSTWithdrawal(_amount)[0];
    }

    /// @notice Initiate stETH withdrawal through Lido queue for 1:1 redemption
    /// @param _amount Amount of LST to queue for withdrawal
    /// @return requestIds Array of NFT IDs we created via our withdrawal
    function _initiateLSTWithdrawal(uint256 _amount)
        internal
        returns (uint256[] memory requestIds)
    {
        IERC20(address(stETH)).forceApprove(address(WITHDRAWAL_QUEUE), _amount);

        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _amount;

        requestIds = WITHDRAWAL_QUEUE.requestWithdrawals(
            _amounts,
            address(this)
        );
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    /// @return _redeemedAmount Amount of LST redeemed
    function claimLSTWithdrawal(uint256 _claimId)
        external
        onlyEmergencyAuthorized
        returns (uint256 _redeemedAmount)
    {
        _redeemedAmount = _claimLSTWithdrawal(_claimId);
    }

    /// @notice Claim ETH from completed Lido withdrawal request
    /// @param _claimId The claim ID from the withdrawal request
    function _claimLSTWithdrawal(uint256 _claimId)
        internal
        returns (uint256 _redeemedAmount)
    {
        uint256 preBalance = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawal(_claimId);
        _redeemedAmount = address(this).balance - preBalance;

        // Convert received ETH to WETH
        weth.deposit{value: address(this).balance}();

        uint256 _pendingRedemptions = pendingRedemptions;
        pendingRedemptions = _redeemedAmount >= _pendingRedemptions
            ? 0
            : _pendingRedemptions - _redeemedAmount;

        if (peg > 0) {
            uint256 toSend = (_redeemedAmount * peg) / 10_000;
            require(
                toSend <
                    estimatedPotentialTotalAssets() +
                        pendingRedemptions -
                        vault.strategies(address(this)).totalDebt,
                "too high"
            );
            IERC20(address(weth)).safeTransfer(WETH_1, toSend);
        }
    }

    /// @notice Manually claim our Lido withdrawals
    /// @dev Only needed if the hint and batch ID are too far from each other.
    function manualClaimWithdrawals(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints,
        bool _zeroRedemptions
    ) external onlyEmergencyAuthorized {
        WITHDRAWAL_QUEUE.claimWithdrawals(_requestIds, _hints);
        if (_zeroRedemptions) {
            pendingRedemptions = 0;
        }
    }

    /// @notice Rescue a stuck withdrawal NFT.
    /// @dev Only may be called by governance.
    function rescueNft(uint256 _requestId) external onlyGovernance {
        WITHDRAWAL_QUEUE.safeTransferFrom(
            address(this),
            governance(),
            _requestId
        );
        // even if this isn't our only NFT, zero redemptions assuming that we will sweep them all
        pendingRedemptions = 0;
    }

    /// @notice Manually zero the pending redemptions in case of significant dust or a Lido slashing event.
    /// @dev Only may be called by governance.
    function zeroPendingRedemptions() external onlyGovernance {
        pendingRedemptions = 0;
    }
}
