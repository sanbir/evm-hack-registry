// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — [H-07] Missing totalFunds update in LiquidityPool's
    openShort(), causing LiquidityPool token holders to lose token value
    (Code4rena 2023-03; finding #20230, reporter auditor0517)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    LiquidityPool.openShort fee handling is inlined VERBATIM (the trader pays the
    fee via a deduction of tradeCost):

        totalCost = tradeCost - fees;
        SUSD.safeTransfer(user, totalCost);   // @> pool keeps the net fee here,
                                              //    but never credits totalFunds

    Root cause: openShort earns the pool a net trading fee (feesCollected -
    externalFee) that is retained as real sUSD, but it is MISSING the
    `totalFunds += feesCollected - externalFee;` update. So the pool's real sUSD
    balance grows by the net fee while totalFunds does not. getTokenPrice (driven
    by totalFunds) is therefore under-stated: LP token holders are not credited
    the fee revenue they earned, and lose that part of their token value.

    Harm class: loss of token value for LP holders. Nothing is stolen by an
    attacker, so this is surfaced as a zero-profit INVARIANT: an LP deposits,
    a short is opened (pool earns a net fee), and on redemption the LP receives
    only its principal — the earned net fee is stuck, uncredited, in the pool.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal fixed-point helpers (solmate-compatible semantics).
library FixedPointMathLib {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * WAD) / y;
    }
}

/// @dev Minimal ERC20 (sUSD), the pool's underlying / LP capital.
contract MockERC20 {
    string public name = "Synthetic USD";
    string public symbol = "sUSD";
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
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev SafeTransferLib shim so openShort compiles verbatim.
library SafeTransferLib {
    function safeTransfer(MockERC20 token, address to, uint256 amt) internal {
        token.transfer(to, amt);
    }
}

/// @notice Reduced LiquidityPool. LP token holders' capital is `totalFunds`;
///         short positions are value-neutral at open (collateral offsets the
///         obligation) except for the fee the pool earns. Contains the verbatim
///         vulnerable openShort fee handling.
contract LiquidityPool {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for MockERC20;

    MockERC20 public SUSD;
    address public devReceipient;

    uint256 public totalFunds;
    uint256 public usedFunds;
    uint256 public amountOwed; // short obligations owed by the pool
    uint256 public amountToCollect; // collateral the pool will collect on those shorts
    uint256 public markPrice = 1e18;
    uint256 public feeRate = 0.02e18; // 2% order fee
    uint256 public devFee = 0.1e18; // 10% of the fee goes to dev/external

    // LP token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(MockERC20 _susd, address _devReceipient) {
        SUSD = _susd;
        devReceipient = _devReceipient;
    }

    function orderFee(uint256 amount) public view returns (uint256) {
        return amount.mulWadDown(feeRate);
    }

    /// @notice LP token price. Reduced form of LiquidityPool.getTokenPrice:
    ///         totalValue = totalFunds + amountToCollect - amountOwed - usedFunds.
    ///         The short position terms net to zero at open, so the price is
    ///         driven by totalFunds — which the fee bug fails to grow.
    function getTokenPrice() public view returns (uint256) {
        if (totalSupply == 0) {
            return 1e18;
        }
        uint256 totalValue = totalFunds + amountToCollect - amountOwed - usedFunds;
        return totalValue.divWadDown(totalSupply);
    }

    /// @notice Deposit sUSD as an LP; mint LP tokens at the current price.
    function deposit(uint256 amount, address user) external {
        uint256 price = getTokenPrice();
        SUSD.transferFrom(msg.sender, address(this), amount);
        uint256 tokens = amount.divWadDown(price);
        balanceOf[user] += tokens;
        totalSupply += tokens;
        totalFunds += amount;
    }

    /// @notice Open a short. VERBATIM reduction of the vulnerable openShort fee
    ///         handling: the trader posts tradeCost, the pool keeps the fee by
    ///         paying out net proceeds, forwards the dev cut — but NEVER credits
    ///         the net fee it earned to totalFunds.
    function openShort(uint256 amount) external returns (uint256 totalCost) {
        uint256 tradeCost = amount.mulWadDown(markPrice);
        uint256 fees = orderFee(amount);
        uint256 hedgingFees = 0; // reduced: external hedge omitted
        uint256 feesCollected = fees - hedgingFees;
        uint256 externalFee = feesCollected.mulWadDown(devFee);

        // Trader posts tradeCost collateral; the short obligation and its
        // matching collateral net to zero in the pool's value at open.
        SUSD.transferFrom(msg.sender, address(this), tradeCost);
        amountOwed += tradeCost;
        amountToCollect += tradeCost;

        // Dev/external portion of the fee leaves the pool.
        SUSD.safeTransfer(devReceipient, externalFee);

        // Trader receives the short proceeds net of fees; the fee stays.
        totalCost = tradeCost - fees;
        SUSD.safeTransfer(msg.sender, totalCost); // @> VULN: pool retains (feesCollected - externalFee) here but never runs `totalFunds += feesCollected - externalFee;`
    }

    /// @notice Redeem all of `user`'s LP tokens at the current price.
    function withdraw(address user) external returns (uint256 susdToReturn) {
        uint256 tokens = balanceOf[user];
        uint256 price = getTokenPrice();
        susdToReturn = tokens.mulWadDown(price);

        balanceOf[user] = 0;
        totalSupply -= tokens;
        totalFunds -= susdToReturn;

        SUSD.transfer(user, susdToReturn);
    }
}

/// @dev Orchestrator: an LP deposits, a trader opens a short (pool earns a net
///      fee), and the LP redeems — receiving only its principal while the
///      earned net fee is stuck uncredited in the pool.
contract Exploit {
    uint256 public constant LP_DEPOSIT = 50e18;
    uint256 public constant SHORT_AMOUNT = 100e18; // tradeCost = 100e18 at markPrice 1.0
    uint256 public constant TRADER_FUNDS = 100e18; // trader posts tradeCost collateral

    address public constant LP = 0x0000000000000000000000000000000000001010; // LP token holder
    address public constant DEV = 0x0000000000000000000000000000000000002020; // dev/external fee sink

    MockERC20 public susd;
    LiquidityPool public pool;

    uint256 public netFee; // feesCollected - externalFee
    uint256 public lpRedeemed;

    constructor() {
        susd = new MockERC20(); // CREATE nonce 1
        pool = new LiquidityPool(susd, DEV); // CREATE nonce 2 (vulnerable)

        // Fund the orchestrator to act as both LP and trader.
        susd.mint(address(this), LP_DEPOSIT + TRADER_FUNDS);
        susd.approve(address(pool), type(uint256).max);
    }

    function run() external {
        // 1. LP deposits 50e18; gets 50e18 LP tokens at price 1e18.
        pool.deposit(LP_DEPOSIT, LP);
        require(pool.totalFunds() == LP_DEPOSIT, "deposit not booked");
        require(pool.balanceOf(LP) == LP_DEPOSIT, "LP tokens not minted");
        require(pool.getTokenPrice() == 1e18, "initial price wrong");

        // Compute the net fee the pool is about to earn.
        uint256 fees = pool.orderFee(SHORT_AMOUNT); // 2e18
        uint256 externalFee = (fees * pool.devFee()) / 1e18; // 0.2e18
        netFee = fees - externalFee; // 1.8e18

        uint256 poolBalBefore = susd.balanceOf(address(pool));

        // 2. A trader opens a short. The pool earns `netFee` (kept as sUSD) but
        //    openShort forgets to credit it to totalFunds.
        pool.openShort(SHORT_AMOUNT);

        // === HARM (accounting) ===
        // The pool's real sUSD balance grew by exactly the net fee...
        require(susd.balanceOf(address(pool)) == poolBalBefore + netFee, "pool didn't retain net fee");
        // ...but totalFunds did NOT (the missing update).
        require(pool.totalFunds() == LP_DEPOSIT, "totalFunds wrongly changed");

        // availableFunds (totalFunds - usedFunds) understates the real balance
        // by the net fee: the earned revenue is invisible to LP accounting.
        uint256 availableFunds = pool.totalFunds() - pool.usedFunds();
        require(availableFunds < susd.balanceOf(address(pool)), "no shortfall in accounting");
        require(susd.balanceOf(address(pool)) - availableFunds == netFee, "shortfall != net fee");

        // getTokenPrice is still 1e18 — it should have risen to reflect the fee.
        require(pool.getTokenPrice() == 1e18, "price should be understated at 1e18");
        // Fair price if the fee were credited: (50 + 1.8)/50 > 1e18.
        uint256 fairPrice = ((LP_DEPOSIT + netFee) * 1e18) / LP_DEPOSIT;
        require(pool.getTokenPrice() < fairPrice, "price not understated");

        // 3. The LP redeems. It gets only its principal back; the net fee it
        //    earned stays stuck in the pool, uncredited.
        lpRedeemed = pool.withdraw(LP);

        // === HARM (loss) ===
        require(lpRedeemed == LP_DEPOSIT, "LP got more/less than principal");
        require(lpRedeemed < LP_DEPOSIT + netFee, "LP was not shortchanged");
        // The uncredited net fee remains locked in the pool with no LP tokens
        // left to claim it.
        require(susd.balanceOf(address(pool)) == netFee, "net fee not stuck");
        require(pool.totalSupply() == 0, "supply should be zero after full redeem");
    }
}
