// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
    Synthetic PoC for AuditVault finding 61176 (Remora Pledge — Cyfrin / Dacian)

    "Accounting on `PaymentSettler` will be corrupted when changing `stablecoin`
     that is used to process payments"

    Root cause: PaymentSettler stores fee/payout accounting in RAW stablecoin
    units. changeStablecoin() swaps the active stablecoin — which may have a
    DIFFERENT number of decimals — WITHOUT rescaling the existing accounting.
    A balance of 100e6 (== 100 USD accrued while the stablecoin had 6 decimals)
    is reinterpreted as 100e6 / 1e8 == 1 USD once an 8-decimal stablecoin is
    installed. The stored raw number never changes; only its decimal meaning
    silently does.

    HARM (accounting corruption): the value the protocol believes it owes /
    holds diverges from the true value. We measure the divergence in a common
    18-decimal USD unit and mint a MARKER for the exact error magnitude to SINK.
*/

/// @dev Faithful minimal ERC20 double with configurable decimals.
contract MiniToken {
    string public name;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory _name, uint8 _decimals) {
        name = _name;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful minimal double of the vulnerable PaymentSettler accounting.
///      Only the decimal-handling on stablecoin change is modelled; unrelated
///      settlement machinery is elided.
contract PaymentSettler {
    address public stablecoin;
    // Accounting kept in RAW units of the CURRENTLY-active stablecoin.
    uint256 public accruedFees;

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    /// @notice Accrue `amount` of fees, expressed in the active stablecoin's raw units.
    function accrueFee(uint256 amount) external {
        accruedFees += amount;
    }

    /// @notice Swap the stablecoin used to process payments.
    ///         VULNERABLE: `accruedFees` (and every other raw-unit accounting
    ///         field) is left untouched, so its decimal interpretation silently
    ///         changes when `newStablecoin` has different decimals.
    function changeStablecoin(address newStablecoin) external {
        stablecoin = newStablecoin; // @> accounting NOT rescaled to new stablecoin's decimals
    }

    /// @notice Read accrued fees normalized to an 18-decimal USD value,
    ///         using the CURRENTLY-active stablecoin's decimals.
    function accruedFeesUsd18() external view returns (uint256) {
        uint8 d = MiniToken(stablecoin).decimals();
        return accruedFees * 1e18 / (10 ** d);
    }
}

/// @dev Mitigation: rescale raw accounting when decimals change (see C-2 fix).
contract PaymentSettlerFixed {
    address public stablecoin;
    uint256 public accruedFees;

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function accrueFee(uint256 amount) external {
        accruedFees += amount;
    }

    function changeStablecoin(address newStablecoin) external {
        uint8 oldDec = MiniToken(stablecoin).decimals();
        uint8 newDec = MiniToken(newStablecoin).decimals();
        // FIX: rescale raw accounting from old decimals to new decimals so the
        // USD value the accounting represents is preserved across the swap.
        if (newDec > oldDec) {
            accruedFees = accruedFees * (10 ** (newDec - oldDec));
        } else if (oldDec > newDec) {
            accruedFees = accruedFees / (10 ** (oldDec - newDec));
        }
        stablecoin = newStablecoin;
    }

    function accruedFeesUsd18() external view returns (uint256) {
        uint8 d = MiniToken(stablecoin).decimals();
        return accruedFees * 1e18 / (10 ** d);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Public results for the driver to assert against.
    uint256 public correctUsd18;   // true USD value of accrued fees (18dp)
    uint256 public corruptedUsd18; // USD value the protocol now believes (18dp)
    uint256 public errorUsd18;     // |correct - corrupted| (the harm magnitude)

    MiniToken public marker;

    function run() external payable {
        // --- Unconditional, fixed-order construction of all helpers ---
        MiniToken usdc6 = new MiniToken("USDC", 6);   // nonce 1
        MiniToken usdc8 = new MiniToken("USDX", 8);   // nonce 2
        PaymentSettler settler = new PaymentSettler(address(usdc6)); // nonce 3

        // --- Preconditions: accrue 100 USD of fees while stablecoin has 6 decimals ---
        uint256 feesRaw6 = 100 * 1e6; // 100 USD at 6 decimals
        settler.accrueFee(feesRaw6);

        // True USD value (18dp) captured BEFORE the swap corrupts the reading.
        correctUsd18 = settler.accruedFeesUsd18(); // 100e18

        // --- Exploit: change to an 8-decimal stablecoin without rescaling ---
        settler.changeStablecoin(address(usdc8));

        // The protocol now reads the SAME raw 100e6 as only 1 USD.
        corruptedUsd18 = settler.accruedFeesUsd18(); // 1e18

        errorUsd18 = correctUsd18 - corruptedUsd18;  // 99e18

        // --- MARKER harm: mint the accounting-error magnitude to SINK (last new) ---
        marker = new MiniToken("HARM", 18); // nonce 4
        marker.mint(SINK, errorUsd18);
    }
}
