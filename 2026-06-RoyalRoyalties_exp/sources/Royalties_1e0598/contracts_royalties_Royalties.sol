//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.2;

import { ECDSAUpgradeable } from "../dependencies/openzeppelin/v4_7_0/ECDSAUpgradeable.sol";
import { EIP712Upgradeable } from "../dependencies/openzeppelin/v4_7_0/draft-EIP712Upgradeable.sol";
import { IERC20Upgradeable } from "../dependencies/openzeppelin/v4_7_0/IERC20Upgradeable.sol";
import { MathUpgradeable } from "../dependencies/openzeppelin/v4_7_0/MathUpgradeable.sol";
import { OwnableUpgradeable } from "../dependencies/openzeppelin/v4_7_0/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "../dependencies/openzeppelin/v4_7_0/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "../dependencies/openzeppelin/v4_7_0/ReentrancyGuardUpgradeable.sol";
import { SafeCastUpgradeable } from "../dependencies/openzeppelin/v4_7_0/SafeCastUpgradeable.sol";
import { SafeERC20Upgradeable } from "../dependencies/openzeppelin/v4_7_0/SafeERC20Upgradeable.sol";

import { IRoyalties } from "./IRoyalties.sol";
import { ILdaTransferHook } from "../interfaces/ILdaTransferHook.sol";
import { RoyalUtil } from "../shared/RoyalUtil.sol";
import { StorageGap } from "../utils/StorageGap.sol";
import { IRoyal1155LDA } from "../ldas/IRoyal1155LDA.sol";

import "hardhat/console.sol";

/**
 * @title Royalties
 * @author Royal
 *
 * @notice Supports the distribution of periodic payments to ERC-1155 holders on a pro-rata basis.
 *
 *  OVERVIEW
 *
 *     A Royalties is initialized with an LDA, PAYMENT_ERC20, and CLAIM_PERIOD_S. The contract can
 *     be used to make payments in the specified ERC-20 token to the holders of LDAs from the
 *     specified LDA contract. Funds from a payment that are unclaimed after the specified claim
 *     period are returned to a “reclaimer” address that is specified for each LDA tier.
 *
 *     To operate correctly, the Royalties contract must be registered on the LDA contract in
 *     order to receive beforeLdaTransfer() callbacks.
 *
 *   PAYMENT LIFECYCLE
 *
 *     Step 1: Tier initializaiton.
 *
 *       An LDA tier must be initialized before it can accept deposits. The tier must be fully
 *       minted before it can be initialized. Also, the “reclaimer” address must be specified.
 *
 *       Currently initialization must be performed by the contract owner, but in the future the
 *       initialization can be triggered automatically as part of tier initialization on the LDA
 *       contract.
 *
 *     Step 2: Royalties deposit.
 *
 *       Anyone may make a deposit to an initialized tier by specifying the tier ID and amount. All
 *       deposits will be made using the ERC-20 token defined by PAYMENT_ERC20. Any deposit is split
 *       evenly among the holders of the LDAs from that tier.
 *
 *     Step 3: Claims.
 *
 *       After deposits are made, the pro rata amounts can be claimed by the accounts that held LDAs
 *       at the time of the deposit. If an LDA owner transfers away their LDA, it does not affect
 *       their rights to claim deposits that they accrued while holding the LDA.
 *
 *       Each deposit may be marked expired after the claming period defined by CLAIM_PERIOD_S has
 *       elapsed. Deposits marked expired may no longer be claimed.
 *
 *     Step 4: Reclaims of expired deposits.
 *
 *       After a deposit has been marked expired, any funds from that deposit that were unclaimed
 *       may be reclaimed by the “reclaimer” address for that tier.
 *
 *   RESTRICTIONS AND FUTURE WORK
 *
 *     - The contract cannot currently support changes to a tier's supply after initialization.
 */
contract Royalties is
    StorageGap,
    EIP712Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ILdaTransferHook,
    IRoyalties
{
    using SafeCastUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //------------------ Structs ------------------//

    // Tier Cumulative Rewards Record
    struct TcrRecord {
        uint128 timestamp;
        uint128 value;
    }

    // User Cumulative Rewards Record
    struct UcrRecord {
        uint64 depositId; // “Last deposit ID at the time of settlement”
        uint64 ldaBalance;
        uint128 value;
    }

    // User Cumulative Expirations Record
    struct UceRecord {
        uint64 depositId; // “Most recent (expired & UCE-settled) OR claimed deposit ID”
        uint64 ucrId; // “Greatest UCR ID such that ucr.depositId <= uce.depositId”
        uint128 value;
    }

    struct UceSettlementLocals {
        uint256 i;
        uint256 j;
        uint256 x;
        uint256 xUcrId;
        uint256 y;
        uint256 yUcrId;
        uint256 p1;
        uint256 p2;
    }

    //------------------ Constants ------------------//

    /// @dev Denotes 100% in the units used to store and calculate pro rata share ownership.
    uint256 public constant PRO_RATA_BASE = 10 ** 18;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRoyal1155LDA public immutable LDA;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20Upgradeable public immutable PAYMENT_ERC20;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable CLAIM_PERIOD_S;

    bytes32 internal constant DEPOSIT_TYPEHASH = keccak256(
        "Deposit(address depositor,uint128 tierId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    bytes32 internal constant CLAIM_TYPEHASH = keccak256(
        "Claim(address claimer,uint128[] tierIds,address recipient,uint256 nonce,uint256 deadline)"
    );

    bytes32 internal constant RECLAIM_TYPEHASH = keccak256(
        "Reclaim(address reclaimer,uint128[] tierIds,address recipient,uint256 nonce,uint256 deadline)"
    );

    //------------------ Storage (Misc) ------------------//

    /// @dev Gap that can be used to for contract upgrades to update base contracts.
    uint256[1_000_000] private __gap;

    /// @dev Current nonce per account for EIP-712 signatures.
    mapping(address => uint256) internal _NONCES_;

    /// @dev Minimum amount for a deposit.
    uint256 internal _MINIMUM_DEPOSIT_AMOUNT_;

    //------------------ Storage (Tier Configuration) ------------------//

    /// @dev Tier configuration.
    mapping(uint128 => TierInfo) internal _TIERS_; // tierId => record

    //------------------ Storage (Tier State) ------------------//

    /// @dev The number of deposits made.
    ///
    ///  The first deposit ID is 1, so this is equal to the last deposit ID.
    ///
    ///  tierId => last deposit ID
    mapping(uint128 => uint256) internal _NUM_DEPOSITS_;

    /// @dev The number of deposits marked as expired.
    ///
    ///   This is equal to the last deposit ID marked as expired.
    ///   All deposits up to and including this ID are considered expired.
    ///
    ///  tierId => last expired deposit ID
    mapping(uint128 => uint256) internal _NUM_EXPIRED_DEPOSITS_;

    /// @dev The number of updates made to a user's Cumulative Royalties (UCR).
    ///
    ///  The first UCR ID is 1, so this is equal to the last UCR ID for the user.
    ///
    ///  tierId => account => last UCR ID
    mapping(uint128 => mapping(address => uint256)) internal _NUM_UCR_RECORDS_;

    /// @dev Tier Cumulative Royalties (TCR).
    ///
    ///  Updated upon deposit and indexed by deposit ID.
    ///
    ///  tierId => depositId => record
    mapping(uint128 => mapping(uint256 => TcrRecord)) internal _TCR_;

    /// @dev User Cumulative Royalties (UCR).
    ///
    ///  Updated upon UCR settlement and indexed by UCR ID.
    ///
    ///  tierId => account => ucrId => record
    mapping(uint128 => mapping(address => mapping(uint256 => UcrRecord))) internal _UCR_;

    /// @dev User Cumulative Expirations (UCE).
    ///
    ///  Updated upon UCE settlement.
    ///
    ///  tierId => account => record
    mapping(uint128 => mapping(address => UceRecord)) internal _UCE_;

    /// @dev Tier Cumulative Expirations (TCE).
    ///
    ///  Updated upon UCE settlement.
    ///
    ///  tierId => value;
    mapping(uint128 => uint256) internal _TCE_;

    /// @dev Cumulative claim amounts.
    ///
    ///  tierId => account => cumulative claimed
    mapping(uint128 => mapping(address => uint256)) internal _CLAIMED_;

    /// @dev Cumulative reclaim amounts.
    ///
    ///  tierId => cumulative reclaimed
    mapping(uint128 => uint256) internal _RECLAIMED_;

    //------------------ Constructor ------------------//

    /// @dev A constructor in an upgradeable contract is generally fine when not used to set
    ///  storage. In this case we are just setting immutable variables, which is safe.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address lda,
        address paymentErc20,
        uint256 claimPeriodSeconds
    )
        initializer
    {
        LDA = IRoyal1155LDA(lda);
        PAYMENT_ERC20 = IERC20Upgradeable(paymentErc20);
        CLAIM_PERIOD_S = claimPeriodSeconds;
    }

    //------------------ Initializer ------------------//

    function initialize()
        external
        initializer
    {
        __EIP712_init_unchained("Royalties", "1");
        __Context_init_unchained();
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    //------------------ Access-restricted external functions ------------------//

    function pause()
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        _pause();
    }

    function unpause()
        external
        onlyOwner
        whenPaused
        nonReentrant
    {
        _unpause();
    }

    function initializeTier(
        uint128 tierId,
        address reclaimer
    )
        external
        onlyOwner
        nonReentrant
    {
        require(
            reclaimer != address(0),
            "Reclaimer address is zero"
        );
        require(
            LDA.tierExists(tierId),
            "Tier does not exist"
        );
        require(
            !LDA.mintable(tierId),
            "Tier not fully minted"
        );

        uint256 supply = LDA.getTierTotalSupply(tierId);

        require(
            supply != 0,
            "Tier has zero supply"
        );

        _TIERS_[tierId] = TierInfo({
            supply: supply,
            reclaimer: reclaimer
        });

        emit TierConfigured(tierId, supply, reclaimer);
    }

    function updateTier(
        uint128 tierId,
        address reclaimer
    )
        external
        onlyOwner
        nonReentrant
    {
        require(
            reclaimer != address(0),
            "Reclaimer address is zero"
        );

        _TIERS_[tierId].reclaimer = reclaimer;

        uint256 supply = _TIERS_[tierId].supply;
        emit TierConfigured(tierId, supply, reclaimer);
    }

    function setMinimumDepositAmount(
        uint256 minimumDepositAmount
    )
        external
        onlyOwner
        nonReentrant
    {
        _MINIMUM_DEPOSIT_AMOUNT_ = minimumDepositAmount;
    }

    /**
     *
     * @notice hook for the LDA contract to call before any token transfer (either mint or user -> user transfer)
     *
     * @param  from    The address of the user who currently owns the LDA, if any
     * @param  to      The address of the user who, after the transaction, will own the LDA, if any
     * @param  tierId  The tierId of the LDA that is being transferred
     */
    function beforeLdaTransfer(
        address from,
        address to,
        uint128 tierId
    )
        external
        override
        nonReentrant
    {
        require(
            msg.sender == address(LDA),
            "Sender is not the LDA contract"
        );
        if (from != address(0)) {
            _settleUcr(tierId, from);
        }
        if (to != address(0)) {
            _settleUcr(tierId, to);
        }
    }

    //------------------ Other external functions ------------------//

    /**
     * @notice Deposit a specified amount of PAYMENT_ERC20 for a particular tierId, with any unclaimed funds reclaimable at refundAddress.
     *
     * @param  depositor  The address of the depositor. Must be msg.sender.
     * @param  tierId     The tierId to deposit funds to.
     * @param  amount     The amount of PAYMENT_ERC20 to transfer from the depositor to the contract.
     */
    function deposit(
        address depositor,
        uint128 tierId,
        uint256 amount
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        require(
            msg.sender == depositor,
            "Sender is not depositor"
        );
        _deposit(depositor, tierId, amount);
    }

    /**
     * @notice EIP-712 compliant function to deposit.
     *
     *  Deposit a specified amount of PAYMENT_ERC20 for a particular tierId, with any unclaimed
     *  funds reclaimable at refundAddress.
     *
     * @param  depositor  The address of the depositor. Must be the signer.
     * @param  tierId     The tierId to deposit funds to.
     * @param  amount     The amount of PAYMENT_ERC20 to transfer from the depositor to the contract.
     * @param  deadline   Deadline for the signature to be valid, in unix seconds
     * @param  v          Signature component V
     * @param  r          Signature component R
     * @param  s          Signature component S
     */
    function depositWithSig(
        address depositor,
        uint128 tierId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        require(
            block.timestamp <= deadline,
            "Expired deadline"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_TYPEHASH,
                depositor,
                tierId,
                amount,
                _useNonce(depositor),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(digest, v, r, s);
        require(
            signer == depositor,
            "Invalid signer"
        );
        _deposit(depositor, tierId, amount);
    }

    /**
     * @notice Claims in batch all available deposits for the user for the given tierIds.
     *
     * @param  claimer    The address of the claimer. Must be msg.sender.
     * @param  tierIds    The tierIds to claim.
     * @param  recipient  The recipient of claimed funds.
     */
    function claim(
        address claimer,
        uint128[] calldata tierIds,
        address recipient
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        require(
            msg.sender == claimer,
            "Sender is not claimer"
        );
        return _claimBatch(claimer, tierIds, recipient);
    }

    /**
     * @notice EIP-712 compliant function to claim.
     *
     *  Claims in batch all available deposits for the user for the given tierIds.
     *
     * @param  claimer    The address of the claimer. Must be the signer.
     * @param  tierIds    The tierIds to claim.
     * @param  recipient  The recipient of claimed funds.
     * @param  deadline   Deadline for the signature to be valid, in unix seconds
     * @param  v          Signature component V
     * @param  r          Signature component R
     * @param  s          Signature component S
     */
    function claimWithSig(
        address claimer,
        uint128[] calldata tierIds,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        require(
            block.timestamp <= deadline,
            "Expired deadline"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                claimer,
                keccak256(abi.encodePacked(tierIds)),
                recipient,
                _useNonce(claimer),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(digest, v, r, s);
        require(
            signer == claimer,
            "Invalid signer"
        );
        _claimBatch(claimer, tierIds, recipient);
    }

    /**
     * @notice Reclaim expired royalties from a tier.
     *
     * @param  tierIds    The tier IDs for which to reclaim.
     * @param  recipient  The recipient of reclaimed funds.
     */
    function reclaim(
        uint128[] calldata tierIds,
        address recipient
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        // Authentication is checked in _reclaimBatch().
        return _reclaimBatch(tierIds, recipient, msg.sender);
    }

    /**
     * @notice EIP-712 compliant function to reclaim.
     *
     * @param  reclaimer  The address of the reclaimer. Must be the signer.
     * @param  tierIds    The tier IDs to reclaim.
     * @param  recipient  The recipient of reclaimed funds.
     * @param  deadline   Deadline for the signature to be valid, in unix seconds
     * @param  v          Signature component V
     * @param  r          Signature component R
     * @param  s          Signature component S
     */
    function reclaimWithSig(
        address reclaimer,
        uint128[] calldata tierIds,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        require(
            block.timestamp <= deadline,
            "Expired deadline"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                RECLAIM_TYPEHASH,
                reclaimer,
                keccak256(abi.encodePacked(tierIds)),
                recipient,
                _useNonce(reclaimer),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(digest, v, r, s);
        require(
            signer == reclaimer,
            "Invalid signer"
        );
        _reclaimBatch(tierIds, recipient, signer);
    }

    function expireDeposits(
        uint128 tierId,
        uint256 expiredDepositId
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        uint256 lastExpiredDepositId = _NUM_EXPIRED_DEPOSITS_[tierId];

        require(
            expiredDepositId > lastExpiredDepositId,
            "Expired deposit ID must increase"
        );
        require(
            expiredDepositId <= _NUM_DEPOSITS_[tierId],
            "Expired deposit ID must exist"
        );

        // IMPORTANT: The expiredDepositId must exist, to get a valid timestamp.
        uint128 depositTimestamp = _TCR_[tierId][expiredDepositId].timestamp;

        require(
            depositTimestamp < block.timestamp - CLAIM_PERIOD_S,
            "Deposit has not expired"
        );

        _NUM_EXPIRED_DEPOSITS_[tierId] = expiredDepositId;

        emit DepositsExpired(tierId, lastExpiredDepositId);
    }

    function settleExpiredRoyalties(
        uint128 tierId,
        address[] calldata accounts
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256[] memory)
    {
        uint256 n = accounts.length;
        uint256[] memory uceArray = new uint256[](n);

        for (uint256 i = 0; i < n;) {
            uint256 oldUce = _UCE_[tierId][accounts[i]].value;
            uint256 newUce = _settleUce(tierId, accounts[i]);
            uceArray[i] = newUce - oldUce;
            unchecked { ++i; }
        }
        return uceArray;
    }

    /**
     * @notice "Consume a nonce": return the current value and increment.
     */
    function cancelNonce(
        address account
    )
        external
        override
        nonReentrant
    {
        require(
            msg.sender == account,
            "Sender is not the account"
        );
        _useNonce(account);
    }

    /**
     * @notice See {IERC20Permit-nonces}.
     */
    function nonces(
        address account
    )
        external
        view
        override
        returns (uint256)
    {
        return _NONCES_[account];
    }

    function getTierInfo(
        uint128 tierId
    )
        external
        view
        override
        returns (TierInfo memory)
    {
        return _TIERS_[tierId];
    }

    function getNumDeposits(
        uint128 tierId
    )
        external
        view
        override
        returns (uint256)
    {
        return _NUM_DEPOSITS_[tierId];
    }

    function getNumExpiredDeposits(
        uint128 tierId
    )
        external
        view
        override
        returns (uint256)
    {
        return _NUM_EXPIRED_DEPOSITS_[tierId];
    }

    function getDeposit(
        uint128 tierId,
        uint256 depositId
    )
        external
        view
        override
        returns (Deposit memory)
    {
        require(
            (
                depositId > 0 &&
                depositId <= _NUM_DEPOSITS_[tierId]
            ),
            "Deposit does not exist"
        );

        TcrRecord memory previousTcr = _TCR_[tierId][depositId - 1];
        TcrRecord memory tcr = _TCR_[tierId][depositId];
        return Deposit({
            amount: tcr.value - previousTcr.value,
            timestamp: tcr.timestamp
        });
    }

    function getMinimumDepositAmount()
        external
        view
        returns (uint256)
    {
        return _MINIMUM_DEPOSIT_AMOUNT_;
    }

    /**
     * @notice Find the value of yUcrId that can be used as a hint for efficient UCE settlement.
     *
     *  While not strictly needed, this serves as a gas optimization to avoid looping over UCR
     *  records in the _settleUce() function.
     *
     *  TODO: Support hints for UCE settlement.
     */
    function findYUcrId(
        uint128 tierId,
        address account
    )
        external
        view
        returns (uint256)
    {
        uint256 j = _NUM_EXPIRED_DEPOSITS_[tierId]; // a.k.a. lastExpiredDepositId

        require(
            j != 0,
            "yUcrId not defined for j = 0"
        );

        UceRecord memory uceRecord = _UCE_[tierId][account];
        uint256 xUcrId = uceRecord.ucrId;
        (uint256 yUcrId, ) = _getY(tierId, account, j, xUcrId, 0, false);
        return yUcrId;
    }

    //------------------ Public functions ------------------//

    function isTierInitialized(
        uint128 tierId
    )
        public
        view
        override
        returns (bool)
    {
        return _TIERS_[tierId].reclaimer != address(0);
    }

    //------------------ Internal functions ------------------//

    /**
     * @dev Internal function that takes a deposit, either by msg.sender or via an EIP-712 signature.
     */
    function _deposit(
        address depositor,
        uint128 tierId,
        uint256 depositAmount
    )
        internal
    {
        require(
            isTierInitialized(tierId),
            "Tier not initialized for deposit"
        );
        require(
            depositAmount >= _MINIMUM_DEPOSIT_AMOUNT_,
            "Deposit amount below minimum"
        );

        // Increment and get deposit ID.
        uint256 depositId = ++_NUM_DEPOSITS_[tierId];

        // Calculate new TCR.
        TcrRecord storage lastTcr = _TCR_[tierId][depositId - 1];
        uint256 newTcr = lastTcr.value + depositAmount;

        // Add TCR record.
        _TCR_[tierId][depositId] = TcrRecord({
            value: newTcr.toUint128(),
            timestamp: block.timestamp.toUint128()
        });

        // Make ERC-20 transfer to the contract.
        PAYMENT_ERC20.safeTransferFrom(depositor, address(this), depositAmount);

        emit Deposited(tierId, depositId, depositor, depositAmount);
    }

    /**
     * @dev Internal function to make claims, either by msg.sender or via an EIP-712 signature.
     */
    function _claimBatch(
        address claimer,
        uint128[] calldata tierIds,
        address recipient
    )
        internal
        returns (uint256[] memory)
    {
        require(
            recipient != address(0),
            "Recipient address cannot be zero"
        );

        uint256 n = tierIds.length;
        uint256[] memory claimableArr = new uint256[](n);

        for (uint256 i = 0; i < n;) {
            uint128 tierId = tierIds[i];
            claimableArr[i] = _claim(claimer, tierId, recipient);

            unchecked { ++i; }
        }

        return claimableArr;
    }

    function _claim(
        address claimer,
        uint128 tierId,
        address recipient
    )
        internal
        returns (uint256)
    {
        // Settle UCR and UCE.
        uint256 ucr = _settleUcr(tierId, claimer);
        uint256 uce = _settleUce(tierId, claimer);

        // Bring UCE depositId up to latest.
        uint256 lastDepositId = _NUM_DEPOSITS_[tierId];
        _UCE_[tierId][claimer].depositId = lastDepositId.toUint64();

        // Calculate claimable amount.
        //
        // Invariant: Claimable = User Cumulative Rewards - User Cumulative Expirations - Claimed
        uint256 oldClaimed = _CLAIMED_[tierId][claimer];
        uint256 newClaimed = ucr - uce;
        uint256 claimable = newClaimed - oldClaimed;

        // Update storage.
        _CLAIMED_[tierId][claimer] = newClaimed;

        // Make ERC-20 transfer to the recipient.
        PAYMENT_ERC20.safeTransfer(recipient, claimable);

        emit Claimed(tierId, claimer, recipient, lastDepositId, claimable);

        return claimable;
    }

    function _reclaimBatch(
        uint128[] calldata tierIds,
        address recipient,
        address signer
    )
        internal
        returns (uint256[] memory)
    {
        require(
            recipient != address(0),
            "Recipient address cannot be zero"
        );
        uint256 n = tierIds.length;
        uint256[] memory reclaimedArr = new uint256[](n);

        for (uint256 i = 0; i < n;) {
            uint128 tierId = tierIds[i];
            address reclaimer = _TIERS_[tierId].reclaimer;

            // Authentication check.
            require(
                signer == reclaimer,
                "Sender/signer is not reclaimer"
            );

            reclaimedArr[i] = _reclaim(tierId, recipient);

            unchecked { ++i; }
        }

        return reclaimedArr;
    }

    function _reclaim(
        uint128 tierId,
        address recipient
    )
        internal
        returns (uint256)
    {
        // Calculate reclaimable amount.
        uint256 oldReclaimed = _RECLAIMED_[tierId];
        uint256 newReclaimed = _TCE_[tierId];
        uint256 reclaimable = newReclaimed - oldReclaimed;

        // Update storage.
        _RECLAIMED_[tierId] = newReclaimed;

        // Make ERC-20 transfer to the recipient.
        PAYMENT_ERC20.safeTransfer(recipient, reclaimable);

        emit Reclaimed(tierId, recipient, reclaimable);

        return reclaimable;
    }

    /**
     * @dev “Consume” a nonce: increment a nonce and return the current value.
     */
    function _useNonce(
        address account
    )
        internal
        returns (uint256)
    {
        uint256 currentNonce = _NONCES_[account];
        unchecked {
            _NONCES_[account] = currentNonce + 1;
        }
        return currentNonce;
    }

    /**
     * @dev Settle the User Cumulative Royalties (UCR) for an account.
     *
     *  This function must be called before the LDA balance of an account changes. It should also
     *  be called before making a claim, in order to get the latest claimable balance for an
     *  account.
     *
     *  This functions calls out to LDA.tierBalanceOf(tierId, account) to get the number of LDAs
     *  held by the account being settled. It is important that the retrieved balance represents
     *  the old balance of the account.
     *
     *  The UCR of an account is tracked historically by a UCR ID. Each UCR record also includes
     *  the last deposit ID at the time of settlement. The UCR only increase over time.
     */
    function _settleUcr(
        uint128 tierId,
        address account
    )
        internal
        returns (uint256)
    {
        uint256 lastUcrId = _NUM_UCR_RECORDS_[tierId][account];
        UcrRecord memory lastUcrRecord = _UCR_[tierId][account][lastUcrId];
        uint128 lastSettledDepositId = lastUcrRecord.depositId;
        uint256 lastDepositId = _NUM_DEPOSITS_[tierId];

        // Calculate the change in UCR and the new UCR.
        uint256 ldaBalance = LDA.tierBalanceOf(tierId, account);

        // If the last TCR entry is zero, then there have never been any (non-zero) deposits to
        // this tier, and the change in UCR is zero.
        uint256 ucrDiff = 0;

        // If the last TCR entry is not zero, calculate the change in UCR.
        TcrRecord memory lastTcrRecord = _TCR_[tierId][lastDepositId];
        if (lastTcrRecord.value != 0) {
            // Calculate the change in TCR between the last settled and last deposit IDs.
            TcrRecord memory lastSettledTcrRecord = _TCR_[tierId][lastSettledDepositId];
            uint256 tcrDiff = lastTcrRecord.value - lastSettledTcrRecord.value;

            // Get the pro rata ownership in base units.
            //
            // IMPORTANT - Proof that division by zero will not occur:
            //
            //     This code path may only run if there have been non-zero deposits.
            //     Existence of deposits implies that the tier has been initialized.
            //     Tier initialized implies that ldaSupply is non-zero.
            uint256 ldaSupply = _TIERS_[tierId].supply;
            uint256 proRataOwnership = _getProRataOwnership(ldaBalance, ldaSupply);

            ucrDiff = _tcrDiffToUcrDiff(tcrDiff, proRataOwnership);
        }

        uint256 newUcrValue = lastUcrRecord.value + ucrDiff;

        // Add the new UCR record.
        unchecked {
            uint256 newUcrId = lastUcrId + 1;
            _NUM_UCR_RECORDS_[tierId][account] = newUcrId;
            _UCR_[tierId][account][newUcrId] = UcrRecord({
                depositId: lastDepositId.toUint64(),
                ldaBalance: ldaBalance.toUint64(),
                value: newUcrValue.toUint128()
            });
        }

        // Return the current UCR value.
        return newUcrValue;
    }

    /**
     * @dev Settle the User Cumulative Expirations (UCE) for an account.
     *
     *  This function must be called before each claim made by a user.
     *
     *  TODO: Add functions that can be used to trigger UCE settlement with an off-chain hint, to
     *  avoid the for-loop.
     */
    function _settleUce(
        uint128 tierId,
        address account
    )
        internal
        returns (uint256)
    {
        UceRecord memory uceRecord = _UCE_[tierId][account];

        UceSettlementLocals memory locals = UceSettlementLocals({
            i: uceRecord.depositId, // a.k.a. lastSettledDepositId,
            j: _NUM_EXPIRED_DEPOSITS_[tierId], // a.k.a. lastExpiredDepositId,
            x: 0,
            xUcrId: 0,
            y: 0,
            yUcrId: 0,
            p1: 0,
            p2: 0
        });

        // There are two cases:
        //
        //   “healthy”  : lastSettledDepositId >= lastExpiredDepositId
        //                No deposit has expired that was not previously claimed by the user,
        //                in other words, none of the user's claims have expired.
        //
        //   “unhealthy”: lastSettledDepositId < lastExpiredDepositId
        //                At least one of the user's claims has expired.
        //
        // Short-circuit in the healthy case.
        if (locals.i >= locals.j) {
            // Return the current UCE value.
            return uceRecord.value;
        }

        // Find change in UCR between lastSettledDepositId and lastExpiredDepositId deposit IDs.
        // This result is the change in UCE (i.e. the newly expired amount).
        //
        // Since UCR records do not necessarily exist for every deposit ID, we may have to
        // interpolate between UCR records to calculate the expired amount.
        //
        // Example:
        //
        //   deposit ID       0    1    2    3    4    5    6
        //
        //   TCR              0    10   20   40   60   80   100
        //
        //   User pro-rata              10%            20%
        //
        //   UCR              0         0              6
        //   -> interpolated       0         2    4         10
        //
        // Define the following references to deposit IDs:
        //
        //   i = lastSettledDepositId
        //   j = lastExpiredDepositId
        //   x = max ucr.depositId such that ucr.depositId <= i (or zero, if no ucr records)
        //   y = max ucr.depositId such that ucr.depositId < j (or zero, if no ucr records)
        //
        // We have the following constraints which follow logically from the above definitions:
        //
        //   x <= i < j
        //   x <= y < j
        //   0 < j <= NUM_DEPOSITS  (i.e. j refers to an existing deposit)
        //
        // There are two cases:
        //
        //   Case x == y:
        //
        //     Then the user's pro-rata share is a constant `p` during the [i, j] period, and
        //       uceDiff = (TCR[j] - TCR[i]) * p
        //
        //   Case x != y:
        //
        //     Then x <= i <= y < j, and
        //     The user's pro-rata share is a constant `p1` during the [x, i] period, and
        //     The user's pro-rata share is a constant `p2` during the [y, j] period, and
        //       uceDiff = (UCR[y] - UCR[x])
        //               - (TCR[i] - TCR[x]) * p1
        //               + (TCR[j] - TCR[y]) * p2
        //
        //   Where UCR[x] denoes the value of the UCR record with deposit ID x,
        //     and TCR[x] denoes the value of the TCR record with deposit ID x.

        locals.xUcrId = uceRecord.ucrId;
        UcrRecord memory xUcr = _UCR_[tierId][account][uceRecord.ucrId];
        locals.x = xUcr.depositId;

        // Find yUcrId and y, or validate and use the provided hint.
        {
            (uint256 yUcrId, uint256 y) = _getY(
                tierId,
                account,
                locals.j,
                uceRecord.ucrId,
                0,
                false
            );
            locals.yUcrId = yUcrId;
            locals.y = y;
        }

        // TODO: Remove these sanity checks later.
        {
            assert(locals.x <= locals.i && locals.i < locals.j);
            assert(locals.x <= locals.y && locals.y < locals.j);
            assert(0 < locals.j && locals.j <= _NUM_DEPOSITS_[tierId]);
        }

        uint256 ldaSupply = _TIERS_[tierId].supply;

        // Calculate the change in UCE (i.e. the newly expired amount).
        uint256 uceDiff;
        if (locals.x == locals.y) {
            {
                uint256 ldaBalance1 = _getLdaBalanceAfterUcr(tierId, account, locals.yUcrId);
                locals.p1 = _getProRataOwnership(ldaBalance1, ldaSupply);
            }
            uint256 tcrDiff = _TCR_[tierId][locals.j].value - _TCR_[tierId][locals.i].value;
            uceDiff = _tcrDiffToUcrDiff(tcrDiff, locals.p1); // uceDiff = ucrDiff
        } else {
            // uceDiff = (UCR[y] - UCR[x])       // user royalties earned between x and y
            //         - (TCR[i] - TCR[x]) * p1  // user royalties earned between x and i
            //         + (TCR[j] - TCR[y]) * p2  // user royalties earned between y and j
            //
            // Example timeline:
            //
            //   | we start with this range |
            //   x             i           y          j
            //   | to remove   | to keep   | to add   |
            //   --------------------------------------
            //
            UcrRecord memory yUcr = _UCR_[tierId][account][locals.yUcrId];
            {
                uint256 ldaBalance1 = _getLdaBalanceAfterUcr(tierId, account, locals.xUcrId);
                uint256 ldaBalance2 = _getLdaBalanceAfterUcr(tierId, account, locals.yUcrId);
                locals.p1 = _getProRataOwnership(ldaBalance1, ldaSupply);
                locals.p2 = _getProRataOwnership(ldaBalance2, ldaSupply);
            }
            uint256 xyUcrDiff = yUcr.value - xUcr.value;
            uint256 xiTcrDiff = _TCR_[tierId][locals.i].value - _TCR_[tierId][locals.x].value;
            uint256 xiUcrDiff = _tcrDiffToUcrDiff(xiTcrDiff, locals.p1);
            uint256 yjTcrDiff = _TCR_[tierId][locals.j].value - _TCR_[tierId][locals.y].value;
            uint256 yjUcrDiff = _tcrDiffToUcrDiff(yjTcrDiff, locals.p2);
            uceDiff = xyUcrDiff - xiUcrDiff + yjUcrDiff;
        }

        // Update storage.
        uint256 newUceValue = uceRecord.value + uceDiff;
        _UCE_[tierId][account] = UceRecord({
            depositId: locals.j.toUint64(), // lastExpiredDepositId
            ucrId: locals.yUcrId.toUint64(),
            value: newUceValue.toUint128()
        });
        _TCE_[tierId] = _TCE_[tierId] + uceDiff;

        emit DepositsReclaimable(
            tierId,
            account,
            locals.j
        );

        // Return the current UCE value.
        return newUceValue;
    }

    /**
     * @dev Get the two values `yUcrId` and `y`.
     *
     *  Definitions:
     *
     *    `yUcrId` is the greatest UCR ID such that the corresponding UCR record has a deposit ID
     *    less than `j` (where `j` is the last expired deposit ID, i.e. _NUM_EXPIRED_DEPOSITS_)
     *
     *    `y` is the deposit ID of the UCR record corresponding to `yUcrId`
     */
    function _getY(
        uint128 tierId,
        address account,
        uint256 j,
        uint256 xUcrId,
        uint256 yUcrIdHint,
        bool useHint
    )
        internal
        view
        returns (
            uint256 yUcrId,
            uint256 y
        )
    {
        if (useHint) {
            yUcrId = yUcrIdHint;
            y = _UCR_[tierId][account][yUcrId].depositId;

            // Verify y is valid. There are two conditions...
            require(
                y < j,
                "Invalid y >= j"
            );
            // If the next UCR ID exists, then it must have a deposit ID >= j.
            uint256 yNextUcrId = yUcrId + 1;
            if (yNextUcrId <= _NUM_UCR_RECORDS_[tierId][account]) {
                uint256 yNext = _UCR_[tierId][account][yNextUcrId].depositId;
                require(
                    yNext >= j,
                    "Invalid yNext < j"
                );
            }
        } else {
            uint256 yNextUcrId;
            for (yNextUcrId = xUcrId + 1; yNextUcrId <= _NUM_UCR_RECORDS_[tierId][account];) {
                UcrRecord memory yNextUcr = _UCR_[tierId][account][yNextUcrId];
                if (yNextUcr.depositId >= j) {
                    break;
                }

                unchecked { ++yNextUcrId; }
            }
            yUcrId = yNextUcrId - 1;
            y = _UCR_[tierId][account][yUcrId].depositId;
        }
    }

    function _getLdaBalanceAfterUcr(
        uint128 tierId,
        address account,
        uint256 ucrId
    )
        internal
        view
        returns (uint256)
    {
        uint256 nextUcrId;
        unchecked {
            nextUcrId = ucrId + 1;
        }
        if (nextUcrId <= _NUM_UCR_RECORDS_[tierId][account]) {
            return _UCR_[tierId][account][nextUcrId].ldaBalance;
        } else {
            // If the next UCR does not exist, query the current LDA balance.
            return LDA.tierBalanceOf(tierId, account);
        }
    }

    function _getProRataOwnership(
        uint256 ldaBalance,
        uint256 ldaSupply
    )
        internal
        pure
        returns (uint256)
    {
        return PRO_RATA_BASE * ldaBalance / ldaSupply;
    }

    function _tcrDiffToUcrDiff(
        uint256 tcrDiff,
        uint256 proRataOwnership
    )
        internal
        pure
        returns (uint256)
    {
        return tcrDiff * proRataOwnership / PRO_RATA_BASE;
    }
}
