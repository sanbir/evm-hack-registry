// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Blast — L1BlastBridge._initiateBridgeERC20 encodes DAI as the local token
    and USDB as the remote token (Spearbit, finding #29874).

    SYNTHETIC, cheatcode-free. L2 finalizeBridgeERC20 transfers _localToken.
    With the report's argument order the user receives 1000 DAI and 0 USDB.
    The fixed encoder passes USDB then DAI, and the user receives 1000 USDB.

    Both tokens are local mocks. No second chain. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract CrossDomainMessenger {
    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external {
        minGasLimit;
        (bool ok,) = target.call(message);
        require(ok, "message failed");
    }
}

contract L2BlastBridge {
    MockToken public dai;
    MockToken public usdb;
    address public paidLocal;
    address public paidRemote;
    address public paidTo;
    uint256 public paidAmount;

    constructor(MockToken dai_, MockToken usdb_) {
        dai = dai_;
        usdb = usdb_;
        dai.mint(address(this), 1000 ether);
        usdb.mint(address(this), 1000 ether);
    }

    function finalizeBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _extraData
    ) external {
        MockToken(_localToken).transfer(_to, _amount);
        paidLocal = _localToken;
        paidRemote = _remoteToken;
        paidTo = _to;
        paidAmount = _amount;
        _from;
        _extraData;
    }
}

contract L1BlastBridge {
    CrossDomainMessenger public messenger;
    L2BlastBridge public l2Bridge;
    MockToken public dai;
    MockToken public usdb;
    uint32 public constant MIN_GAS = 200_000;

    constructor(CrossDomainMessenger messenger_, L2BlastBridge l2, MockToken dai_, MockToken usdb_) {
        messenger = messenger_;
        l2Bridge = l2;
        dai = dai_;
        usdb = usdb_;
    }

    /// @notice Report's encoder. DAI is passed where the L2 local token belongs.
    function initiateBridgeERC20(address _from, address _to, uint256 amountToMintWad, bytes memory _extraData)
        external
    {
        // @> VULN: DAI is encoded as _localToken and USDB as _remoteToken, so L2 transfers DAI
        bytes memory message = abi.encodeWithSelector(
            L2BlastBridge.finalizeBridgeERC20.selector,
            address(dai),
            address(usdb),
            _from,
            _to,
            amountToMintWad,
            _extraData
        );
        messenger.sendMessage(address(l2Bridge), message, MIN_GAS);
    }
}

contract L1BlastBridgeFixed {
    CrossDomainMessenger public messenger;
    L2BlastBridge public l2Bridge;
    MockToken public dai;
    MockToken public usdb;
    uint32 public constant MIN_GAS = 200_000;

    constructor(CrossDomainMessenger messenger_, L2BlastBridge l2, MockToken dai_, MockToken usdb_) {
        messenger = messenger_;
        l2Bridge = l2;
        dai = dai_;
        usdb = usdb_;
    }

    function initiateBridgeERC20(address _from, address _to, uint256 amountToMintWad, bytes memory _extraData)
        external
    {
        bytes memory message = abi.encodeWithSelector(
            L2BlastBridge.finalizeBridgeERC20.selector,
            address(usdb),
            address(dai),
            _from,
            _to,
            amountToMintWad,
            _extraData
        );
        messenger.sendMessage(address(l2Bridge), message, MIN_GAS);
    }
}

contract Exploit {
    MockToken public dai;
    MockToken public usdb;
    CrossDomainMessenger public messenger;
    L2BlastBridge public l2;
    L1BlastBridge public l1;
    L1BlastBridgeFixed public fixedL1;

    uint256 public receivedDai;
    uint256 public receivedUsdb;

    constructor() {
        dai = new MockToken("Dai Stablecoin", "DAI");
        usdb = new MockToken("USDB", "USDB");
        messenger = new CrossDomainMessenger();
        l2 = new L2BlastBridge(dai, usdb);
        l1 = new L1BlastBridge(messenger, l2, dai, usdb);
        fixedL1 = new L1BlastBridgeFixed(messenger, l2, dai, usdb);
    }

    function run() external {
        l1.initiateBridgeERC20(address(this), address(this), 1000 ether, bytes(""));
        receivedDai = dai.balanceOf(address(this));
        receivedUsdb = usdb.balanceOf(address(this));
        require(l2.paidLocal() == address(dai), "L2 local token was not DAI");
        require(l2.paidRemote() == address(usdb), "L2 remote token was not USDB");
        require(receivedDai == 1000 ether, "user did not receive 1000 DAI");
        require(receivedUsdb == 0, "user received USDB");
        require(usdb.balanceOf(address(l2)) == 1000 ether, "USDB left the bridge");
        require(dai.balanceOf(address(l2)) == 0, "DAI stayed on the bridge");
    }

    function control(address to) external {
        fixedL1.initiateBridgeERC20(to, to, 1000 ether, bytes(""));
        require(usdb.balanceOf(to) == 1000 ether, "control did not pay 1000 USDB");
        require(dai.balanceOf(to) == 0, "control paid DAI");
        require(l2.paidLocal() == address(usdb), "control local was not USDB");
        require(l2.paidRemote() == address(dai), "control remote was not DAI");
    }
}
