// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Blast — L2BlastBridge.finalizeBridgeETHDirect compares msg.sender to the
    un-aliased L1BlastBridge (Spearbit, finding #29873).

    SYNTHETIC, cheatcode-free, L2-side only. A direct L1-to-L2 deposit sets
    msg.sender to alias(L1BlastBridge), not to OTHER_BRIDGE. The require below
    is the report's line, verbatim. It always reverts, so the 5 stETH deposit
    stays in the L1 escrow and the depositor is credited 0 ETH.

    AliasedMessenger is deployed first. OTHER_BRIDGE is undoL1ToL2Alias of that
    address, using the OP-stack offset 0x1111...1111. No second chain. */

uint160 constant ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);

function applyL1ToL2Alias(address l1Address) pure returns (address l2Address) {
    unchecked {
        l2Address = address(uint160(l1Address) + ALIAS_OFFSET);
    }
}

function undoL1ToL2Alias(address l2Address) pure returns (address l1Address) {
    unchecked {
        l1Address = address(uint160(l2Address) - ALIAS_OFFSET);
    }
}

contract MockStETH {
    string public name = "Lido Staked ETH";
    string public symbol = "stETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice L2 view of a direct L1BlastBridge deposit. Its address IS the alias.
contract AliasedMessenger {
    function finalize(address bridge, address to, uint256 amount) external payable returns (bool ok) {
        (ok,) = bridge.call{value: msg.value}(
            abi.encodeWithSelector(
                L2BlastBridge.finalizeBridgeETHDirect.selector, msg.sender, to, amount, bytes("")
            )
        );
    }
}

contract L2BlastBridge {
    address public immutable OTHER_BRIDGE;
    address public messenger;
    uint256 public released;

    constructor(address otherBridge) {
        OTHER_BRIDGE = otherBridge;
        messenger = address(0x4200000000000000000000000000000000000007);
    }

    /// @notice Direct L1-to-L2 ETH finalize. The report's check is the first require.
    function finalizeBridgeETHDirect(address _from, address _to, uint256 _amount, bytes calldata _extraData)
        public
        payable
    {
        // @> VULN: msg.sender is alias(L1BlastBridge), not OTHER_BRIDGE, so this always reverts
        require(msg.sender == address(OTHER_BRIDGE), "StandardBridge: function can only be called from the other bridge");
        require(msg.value == _amount, "StandardBridge: amount sent does not match amount required");
        require(_to != address(this), "StandardBridge: cannot send to self");
        require(_to != address(messenger), "StandardBridge: cannot send to messenger");
        (bool success,) = _to.call{value: _amount}("");
        require(success, "L2BlastBridge: ETH transfer failed");
        released += _amount;
        _from;
        _extraData;
    }
}

contract L2BlastBridgeFixed {
    address public immutable OTHER_BRIDGE;
    address public messenger;
    uint256 public released;

    constructor(address otherBridge) {
        OTHER_BRIDGE = otherBridge;
        messenger = address(0x4200000000000000000000000000000000000007);
    }

    function finalizeBridgeETHDirect(address _from, address _to, uint256 _amount, bytes calldata _extraData)
        public
        payable
    {
        require(
            undoL1ToL2Alias(msg.sender) == address(OTHER_BRIDGE),
            "StandardBridge: function can only be called from the other bridge"
        );
        require(msg.value == _amount, "StandardBridge: amount sent does not match amount required");
        require(_to != address(this), "StandardBridge: cannot send to self");
        require(_to != address(messenger), "StandardBridge: cannot send to messenger");
        (bool success,) = _to.call{value: _amount}("");
        require(success, "L2BlastBridge: ETH transfer failed");
        released += _amount;
        _from;
        _extraData;
    }
}

contract L1BlastEscrow {
    MockStETH public immutable steth;
    uint256 public locked;

    constructor(MockStETH s) {
        steth = s;
    }

    function deposit(uint256 amount) external {
        steth.transferFrom(msg.sender, address(this), amount);
        locked += amount;
    }
}

contract Depositor {
    MockStETH public immutable steth;
    L1BlastEscrow public immutable escrow;

    constructor(MockStETH s, L1BlastEscrow e) {
        steth = s;
        escrow = e;
    }

    function deposit(uint256 amount) external {
        steth.approve(address(escrow), amount);
        escrow.deposit(amount);
    }

    receive() external payable {}
}

contract Exploit {
    MockStETH public steth;
    AliasedMessenger public relay;
    L2BlastBridge public bridge;
    L2BlastBridgeFixed public fixedBridge;
    L1BlastEscrow public escrow;
    Depositor public depositor;

    uint256 public lockedSteth;
    uint256 public creditedEth;
    bool public finalizeReverted;

    constructor() {
        steth = new MockStETH();
        relay = new AliasedMessenger();
        address other = undoL1ToL2Alias(address(relay));
        bridge = new L2BlastBridge(other);
        fixedBridge = new L2BlastBridgeFixed(other);
        escrow = new L1BlastEscrow(steth);
        depositor = new Depositor(steth, escrow);
    }

    function run() external {
        uint256 n = 5 ether;
        steth.mint(address(depositor), n);
        depositor.deposit(n);
        require(applyL1ToL2Alias(bridge.OTHER_BRIDGE()) == address(relay), "relay is not the alias");
        require(address(relay) != bridge.OTHER_BRIDGE(), "alias collapsed");
        bool ok = relay.finalize(address(bridge), address(depositor), n);
        finalizeReverted = !ok;
        lockedSteth = steth.balanceOf(address(escrow));
        creditedEth = address(depositor).balance;
        require(finalizeReverted, "alias check must revert");
        require(lockedSteth == n, "5 stETH not locked");
        require(creditedEth == 0, "depositor was credited ETH");
        require(bridge.released() == 0, "buggy bridge released ETH");
    }

    function control() external payable {
        uint256 n = 5 ether;
        require(msg.value == n, "seed");
        steth.mint(address(depositor), n);
        depositor.deposit(n);
        bool ok = relay.finalize{value: n}(address(fixedBridge), address(depositor), n);
        require(ok, "fixed finalize reverted");
        require(address(depositor).balance == n, "control did not credit 5 ETH");
        require(fixedBridge.released() == n, "control did not release");
    }
}
