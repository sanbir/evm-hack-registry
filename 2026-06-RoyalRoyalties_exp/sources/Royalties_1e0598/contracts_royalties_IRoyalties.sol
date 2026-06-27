// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IRoyalties {

    //------------------ Structs ------------------//

    struct TierInfo {
        uint256 supply;
        address reclaimer;
    }

    struct Deposit {
        uint128 amount;
        uint128 timestamp;
    }

    //------------------ Events ------------------//

    event TierConfigured(
        uint256 indexed tierId,
        uint256 supply,
        address reclaimer
    );

    event Deposited(
        uint256 indexed tierId,
        uint256 indexed depositId,
        address indexed depositor,
        uint256 amount
    );

    event Claimed(
        uint256 indexed tierId,
        address indexed claimer,
        address indexed recipient,
        uint256 lastDepositId,
        uint256 amount
    );

    event DepositsExpired(
        uint256 indexed tierId,
        uint256 lastExpiredDepositId
    );

    event DepositsReclaimable(
        uint256 indexed tierId,
        address indexed claimer,
        uint256 lastExpiredDepositId
    );

    event Reclaimed(
        uint256 indexed tierId,
        address indexed recipient,
        uint256 amount
    );

    //------------------ State-changing functions ------------------//

    function deposit(
        address depositor,
        uint128 tierId,
        uint256 amount
    )
        external;

    function depositWithSig(
        address depositor,
        uint128 tierId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external;

    function claim(
        address claimer,
        uint128[] calldata tierIds,
        address recipient
    )
        external
        returns (uint256[] memory);

    function claimWithSig(
        address claimer,
        uint128[] calldata tierIds,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external;

    function reclaim(
        uint128[] calldata tierIds,
        address recipient
    )
        external
        returns (uint256[] memory);

    function reclaimWithSig(
        address reclaimer,
        uint128[] calldata tierIds,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external;

    function expireDeposits(
        uint128 tierId,
        uint256 expiredDepositId
    )
        external;

    function settleExpiredRoyalties(
        uint128 tierId,
        address[] calldata accounts
    )
        external
        returns (uint256[] memory);

    function cancelNonce(
        address account
    )
        external;

    //------------------ View functions ------------------//

    function nonces(
        address account
    )
        external
        view
        returns (uint256);

    function getTierInfo(
        uint128 tierId
    )
        external
        view
        returns (TierInfo memory);

    function getNumDeposits(
        uint128 tierId
    )
        external
        view
        returns (uint256);

    function getNumExpiredDeposits(
        uint128 tierId
    )
        external
        view
        returns (uint256);

    function getDeposit(
        uint128 tierId,
        uint256 depositId
    )
        external
        view
        returns (Deposit memory);

    function isTierInitialized(
        uint128 tierId
    )
        external
        view
        returns (bool);
}
