// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of Resolv finding 62187 (H-01):
// "`transferFee()` uses an incorrect transfer method".
//
// Source (Pashov Audit Group — Resolv 2024-12-09), TheCounter contract. The
// vulnerable line is reproduced VERBATIM (marked @>):
//   token.safeTransferFrom(address(this), msg.sender, feeToTransfer);  // should be safeTransfer
//
// Root cause: to move the contract's OWN tokens out, the code must call
// `safeTransfer`. Using `safeTransferFrom(address(this), ...)` requires the
// contract to have granted itself an allowance — which it never does — so every
// fee withdrawal reverts and the accumulated protocol fees are permanently stuck.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address o, address s) external view returns (uint256);
}

/// @dev Faithful minimal SafeERC20: forwards to transfer/transferFrom and reverts on failure.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

/// @dev Faithful minimal ERC20 with real allowance-checked transferFrom.
contract MiniToken is IERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "insufficient allowance"); // real allowance enforcement
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the withdrawal line is reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract TheCounter {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable admin;
    uint256 public accumulatedFee;

    constructor(IERC20 _token, address _admin) { token = _token; admin = _admin; }

    modifier onlyRole() { require(msg.sender == admin, "AccessControl: missing role"); _; }

    function accrueFee(uint256 amount) external { accumulatedFee += amount; }

    function transferFee() external onlyRole {
        uint256 feeToTransfer = accumulatedFee;
        accumulatedFee = 0;
        token.safeTransferFrom(address(this), msg.sender, feeToTransfer); // @> VULN: uses safeTransferFrom to move the contract's OWN tokens (needs a self-allowance it never grants) instead of safeTransfer, so this always reverts and fees are stuck
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: as the admin, accrue fees and prove `transferFee()` always
// reverts, so the protocol fees are permanently unrecoverable.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant FEE = 100e18;

    MiniToken public token;   // child nonce 1 (marker of the stuck fee)
    TheCounter public vuln;   // child nonce 2 (VULN)

    bool public transferFeeReverts;
    uint256 public stuckFee;

    constructor() {
        token = new MiniToken();                              // nonce 1
        vuln = new TheCounter(IERC20(address(token)), address(this)); // nonce 2 — Exploit is the admin
    }

    function run() external {
        // protocol collects 100e18 of fees into TheCounter
        token.mint(address(vuln), FEE);
        vuln.accrueFee(FEE);

        // admin (this contract) tries to withdraw the fees -> reverts inside safeTransferFrom
        try vuln.transferFee() {
            transferFeeReverts = false;
        } catch {
            transferFeeReverts = true;
        }

        stuckFee = token.balanceOf(address(vuln)); // fees remain trapped in the contract

        // harm: the admin can never collect the accrued fees
        require(transferFeeReverts, "transferFee unexpectedly succeeded");
        require(stuckFee == FEE, "fees not stuck");

        // record the permanently-stuck fee magnitude on the marker to SINK
        token.mint(SINK, stuckFee);
    }
}
