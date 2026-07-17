// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import {IERC20} from "contracts/BaseStrategy.sol";

interface ISteth is IERC20 {
    event Submitted(address sender, uint256 amount, address referral);

    function submit(address) external payable returns (uint256);
}

interface IQueue {
    /// @notice output format struct for `_getWithdrawalStatus()` method
    struct WithdrawalRequestStatus {
        /// @notice stETH token amount that was locked on withdrawal queue for this request
        uint256 amountOfStETH;
        /// @notice amount of stETH shares locked on withdrawal queue for this request
        uint256 amountOfShares;
        /// @notice address that can claim or transfer this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    function claimWithdrawal(uint256 _requestId) external;

    function claimWithdrawals(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external;

    function requestWithdrawals(uint256[] calldata _amounts, address _owner)
        external
        returns (uint256[] memory requestIds);

    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _requestId
    ) external;

    function getWithdrawalRequests(address)
        external
        view
        returns (uint256[] memory);

    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);

    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function decimals() external view returns (uint256);

    function withdraw(uint256) external;
}

interface ICurveFi {
    function get_virtual_price() external view returns (uint256);

    function add_liquidity(
        // sBTC pool
        uint256[3] calldata amounts,
        uint256 min_mint_amount
    ) external;

    function add_liquidity(
        // bUSD pool
        uint256[4] calldata amounts,
        uint256 min_mint_amount
    ) external;

    function add_liquidity(
        // stETH pool
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external payable;

    function remove_liquidity_imbalance(
        uint256[4] calldata amounts,
        uint256 max_burn_amount
    ) external;

    function remove_liquidity(uint256 _amount, uint256[4] calldata amounts)
        external;

    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 min_amount
    ) external;

    function exchange(
        int128 from,
        int128 to,
        uint256 _from_amount,
        uint256 _min_to_amount
    ) external payable;

    function balances(int128) external view returns (uint256);

    function get_dy(
        int128 from,
        int128 to,
        uint256 _from_amount
    ) external view returns (uint256);

    function calc_token_amount(uint256[2] calldata amounts, bool is_deposit)
        external
        view
        returns (uint256);
}
