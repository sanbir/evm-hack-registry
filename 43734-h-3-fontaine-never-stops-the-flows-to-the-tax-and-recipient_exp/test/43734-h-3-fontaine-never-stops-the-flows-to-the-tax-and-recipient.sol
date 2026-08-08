// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Superfluid Locking Contract — Fontaine never stops the flows to the tax
    and recipient, so the buffer component of the flows will be lost
    (Sherlock 2024-11-superfluid-locking-contract, #43734, H-3)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable Fontaine.initialize body is reduced with the blamed create/
    distribute flow setup preserved and NO stop-flow / reclaim path. Superfluid
    reserves 4 hours of flow-rate as a deposit buffer on flow open and only
    returns it when the flow is closed; because Fontaine never closes, that
    buffer is permanently lost to the recipient and tax pool (no fork, no
    cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: Fontaine.initialize opens a tax distributeFlow and a recipient
    createFlow, then provides no mechanism to stop those flows and reclaim the
    Superfluid deposit buffer. When the unlock period ends the streamed
    portion has been paid out, but the reserved buffer remains locked forever.

    Recommended fix (per report): add a way to stop the flow and receive the
    deposit back (e.g. close flows at end of unlock and forward residual).
//////////////////////////////////////////////////////////////*/

/// @dev Minimal SuperToken-like mock: createFlow / distributeFlow reserve a
///      4-hour buffer from the caller's balance; stopFlow returns it.
contract MockFluid {
    uint256 public constant BUFFER_DURATION = 4 hours;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockedBuffer; // permanently reserved unless stopFlow
    mapping(address => int96) public outflowRate;
    mapping(address => address) public outflowTo;
    mapping(address => int96) public taxFlowRate;
    address public taxPool;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev Open a CFA-style flow; reserve buffer = rate * 4 hours.
    function createFlow(address receiver, int96 flowRate) external {
        require(flowRate > 0, "rate");
        uint256 buffer = uint256(uint96(flowRate)) * BUFFER_DURATION;
        require(balanceOf[msg.sender] >= buffer, "buffer");
        balanceOf[msg.sender] -= buffer;
        lockedBuffer[msg.sender] += buffer;
        outflowRate[msg.sender] = flowRate;
        outflowTo[msg.sender] = receiver;
    }

    /// @dev Open a GDA-style distribute flow; same buffer reservation model.
    function distributeFlow(address /*from*/, address pool, int96 flowRate) external {
        require(flowRate > 0, "rate");
        uint256 buffer = uint256(uint96(flowRate)) * BUFFER_DURATION;
        require(balanceOf[msg.sender] >= buffer, "buffer");
        balanceOf[msg.sender] -= buffer;
        lockedBuffer[msg.sender] += buffer;
        taxFlowRate[msg.sender] = flowRate;
        taxPool = pool;
    }

    /// @dev The fix path: stop flows and reclaim deposit buffer.
    function stopFlow(address /*receiver*/) external {
        uint256 buf = lockedBuffer[msg.sender];
        lockedBuffer[msg.sender] = 0;
        balanceOf[msg.sender] += buf;
        outflowRate[msg.sender] = 0;
        taxFlowRate[msg.sender] = 0;
    }

    /// @dev Simulate the unlock period elapsing: stream available (non-buffer)
    ///      balance to recipient + tax proportional to their rates.
    function settleStream(address from) external {
        uint256 available = balanceOf[from];
        if (available == 0) return;
        int96 outR = outflowRate[from];
        int96 taxR = taxFlowRate[from];
        int96 totalR = outR + taxR;
        require(totalR > 0, "no flows");
        uint256 toRecipient = (available * uint256(uint96(outR))) / uint256(uint96(totalR));
        uint256 toTax = available - toRecipient;
        balanceOf[from] = 0;
        balanceOf[outflowTo[from]] += toRecipient;
        balanceOf[taxPool] += toTax;
    }
}

/// @dev Reduced Fontaine — initialize opens flows and never stops them.
contract Fontaine {
    MockFluid public immutable FLUID;
    address public immutable TAX_DISTRIBUTION_POOL;
    address public recipient;
    bool public initialized;

    constructor(MockFluid fluid, address taxPool) {
        FLUID = fluid;
        TAX_DISTRIBUTION_POOL = taxPool;
    }

    /// @dev VERBATIM reduction of Fontaine.initialize
    ///      (fluid/packages/contracts/src/Fontaine.sol#L61 area).
    function initialize(address unlockRecipient, int96 unlockFlowRate, int96 taxFlowRate) external {
        require(!initialized, "init");
        initialized = true;
        recipient = unlockRecipient;

        // Distribute Tax flow to Staker GDA Pool
        FLUID.distributeFlow(address(this), TAX_DISTRIBUTION_POOL, taxFlowRate);

        // Create the unlocking flow from the Fontaine to the locker owner
        FLUID.createFlow(unlockRecipient, unlockFlowRate); // @> VULN: flows opened here are NEVER stopped — no endUnlock/stopFlow path, so the Superfluid 4h deposit buffer is never reclaimed
        // FIX: provide a permissionless end-of-unlock that calls FLUID.stopFlow(unlockRecipient)
        // (and stops the tax flow) then forwards residual buffer to recipient/tax.
    }

    // Intentionally NO stop / reclaim function — that is the bug.
}

/// @dev Tax pool / recipient placeholders.
contract Pool {
    // receives streamed tokens via MockFluid.balanceOf
}

/// @notice Orchestrator.
/// CREATE order: (1) fluid (2) taxPool (3) recipient (4) fontaine
contract Exploit {
    MockFluid public fluid;     // CREATE nonce 1
    Pool public taxPool;        // CREATE nonce 2
    Pool public recipient;      // CREATE nonce 3
    Fontaine public fontaine;   // CREATE nonce 4 — vulnerable

    uint256 public constant UNLOCK_AMOUNT = 10_000 ether;
    // Rates chosen so 4h buffers sum to 3.2 ether (matches finding's 10000 → 9996.8 residual).
    // buffer_total = (unlockRate + taxRate) * 4 hours = 3.2e18
    // => unlockRate + taxRate = 3.2e18 / 14400 = 2.222...e14
    int96 public constant UNLOCK_RATE = int96(int256(2e14));      // ~2e14
    int96 public constant TAX_RATE = int96(int256(22222222222222)); // ~0.222e14
    // total rate ≈ 2.222e14; * 14400 ≈ 3.2e18

    constructor() {
        fluid = new MockFluid();
        taxPool = new Pool();
        recipient = new Pool();
        fontaine = new Fontaine(fluid, address(taxPool));
    }

    function run() external {
        // Fund the Fontaine with the unlock amount (as Locker would).
        fluid.mint(address(fontaine), UNLOCK_AMOUNT);

        uint256 fontaineBefore = fluid.balanceOf(address(fontaine));
        require(fontaineBefore == UNLOCK_AMOUNT, "seed");

        // Unlock with non-null period: open tax + recipient flows (reserves buffers).
        fontaine.initialize(address(recipient), UNLOCK_RATE, TAX_RATE);

        uint256 bufferLocked = fluid.lockedBuffer(address(fontaine));
        require(bufferLocked > 0, "buffer should be reserved");
        // Finding: 10000e18 in → 9996.8e18 left as streamable (3.2e18 buffer).
        require(bufferLocked == (uint256(uint96(UNLOCK_RATE)) + uint256(uint96(TAX_RATE))) * 4 hours, "buf math");

        uint256 streamable = fluid.balanceOf(address(fontaine));
        require(streamable + bufferLocked == UNLOCK_AMOUNT, "conservation");
        require(streamable < UNLOCK_AMOUNT, "buffer took a cut");

        // Simulate the unlock period fully elapsing: stream remaining free balance out.
        fluid.settleStream(address(fontaine));

        uint256 received =
            fluid.balanceOf(address(recipient)) + fluid.balanceOf(address(taxPool));
        // Recipient + tax got only the streamable portion — NOT the buffer.
        require(received == streamable, "streamed only free balance");
        require(received < UNLOCK_AMOUNT, "short of full unlock");

        // HARM: buffer is still locked on Fontaine forever (no stopFlow ever called).
        require(fluid.lockedBuffer(address(fontaine)) == bufferLocked, "buffer still locked");
        require(fluid.balanceOf(address(fontaine)) == 0, "free balance drained");
        // The lost amount equals the buffer that a stopFlow would have reclaimed.
        uint256 lost = UNLOCK_AMOUNT - received;
        require(lost == bufferLocked, "lost == unreclaimed buffer");
        require(lost >= 3 ether, "material buffer loss"); // ~3.2e18
    }
}
