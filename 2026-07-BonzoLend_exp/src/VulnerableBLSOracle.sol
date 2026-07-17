// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @notice RECONSTRUCTED teaching model of Supra's vulnerable BLS path on Hedera
///         (contract 0.0.4323006 / requireHashVerified_V2), distilled from the
///         BlockSec + Bonzo Finance public incident reports (July 2026).
///
/// Root cause: BLS.verifySingle / requireHashVerified_V2 call the BN254 pairing
/// precompile (0x08) WITHOUT rejecting the G1/G2 identity (zero) points. Under
/// EIP-197 the pairing product over identity inputs is the multiplicative
/// identity, so the precompile returns true. A zeroed committee public key plus
/// a zeroed signature therefore "verifies" any message — including a forged
/// SAUCE/WHBAR price root.
///
/// This file is intentionally self-contained (no external imports) so it can be
/// shipped inside the registry sources/ tree and highlighted in the playground.

/// @dev Minimal ERC-20 used as SAUCE collateral and USDC borrow asset in the PoC.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Vulnerable BLS helper — mirrors the missing zero-point checks.
library VulnerableBLS {
    /// @notice Pairing check e(sig, nG2) * e(H(msg), pk) == 1, WITHOUT input validation.
    /// @dev When sig == (0,0) and pk == (0,0,0,0) every limb of the 12-word pairing
    ///      input is zero. Precompile 0x08 returns 1 (true) for that product.
    function verifySingle(
        uint256[2] memory signature,
        uint256[4] memory pubkey,
        uint256[2] memory message
    ) internal view returns (bool checkSuccess, bool callSuccess) {
        // Negated G2 generator (BN254) — same constants used by common Solidity BLS libs.
        // Values unused when signature and pubkey are the identity, but kept for fidelity
        // of the call shape that Supra's requireHashVerified_V2 used.
        uint256 nG2x1 = 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2;
        uint256 nG2x0 = 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed;
        uint256 nG2y1 = 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b;
        uint256 nG2y0 = 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa;

        uint256[12] memory input;
        input[0] = signature[0];
        input[1] = signature[1];
        input[2] = nG2x1;
        input[3] = nG2x0;
        input[4] = nG2y1;
        input[5] = nG2y0;
        input[6] = message[0];
        input[7] = message[1];
        input[8] = pubkey[1];
        input[9] = pubkey[0];
        input[10] = pubkey[3];
        input[11] = pubkey[2];

        uint256[1] memory out;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            callSuccess := staticcall(gas(), 0x08, input, 0x180, out, 0x20)
        }
        checkSuccess = out[0] != 0;
    }

    /// @dev Hash-to-point stand-in. Real Supra uses BLS.hashToPoint(domain, …).
    ///      The pairing precompile requires on-curve G1 points; (1,2) is the BN254
    ///      G1 generator. For the zero-sig exploit both signature and pubkey are the
    ///      identity, so e(O, nG2)·e(H, O) = 1 regardless of which valid H is used —
    ///      but an off-curve H makes the precompile *revert* (callSuccess=false),
    ///      which is a different failure mode than the live bug.
    function hashToPoint(bytes32 /*message*/) internal pure returns (uint256[2] memory p) {
        p[0] = 1;
        p[1] = 2;
    }
}

/// @dev Supra-style verifier with the buggy requireHashVerified_V2.
contract VulnerableSupraVerifier {
    /// @notice Committee public keys. Index 2 is intentionally left as the G2
    ///         identity (all zeros) — matching the Hedera incident state that
    ///         Bonzo Finance reported for committee ID 2.
    mapping(uint256 => uint256[4]) public committeePublicKey;

    error BLSInvalidPublicKeyorSignaturePoints();
    error BLSIncorrectInputMessaage();

    /// @dev Reproduce requireHashVerified_V2: NO zero-point rejection.
    function requireHashVerified_V2(
        bytes32 message,
        uint256[2] calldata signature,
        uint256 committeeId
    ) public view {
        bool callSuccess;
        bool checkSuccess;
        (checkSuccess, callSuccess) = VulnerableBLS.verifySingle(
            signature,
            committeePublicKey[committeeId],
            VulnerableBLS.hashToPoint(message)
        );
        if (!callSuccess) revert BLSInvalidPublicKeyorSignaturePoints();
        if (!checkSuccess) revert BLSIncorrectInputMessaage();
    }
}

/// @dev Pull-oracle feed: accepts a root after requireHashVerified_V2, writes prices.
contract VulnerablePullOracle {
    VulnerableSupraVerifier public immutable verifier;
    mapping(bytes32 => bool) public merkleSet;
    /// @notice pairId => packed price (raw integer as stored on-chain).
    mapping(uint256 => uint256) public priceOf;
    mapping(uint256 => uint256) public updatedAt;

    error RootIsZero();
    error RootAlreadySeen();

    uint256 public constant PAIR_SAUCE_WHBAR = 425;

    constructor(VulnerableSupraVerifier v) {
        verifier = v;
    }

    /// @dev Simplified verifyOracleProofV2 path for a single forged feed update.
    ///      Historical attack used committeeId=2, sigs=[0,0], pair=425, price=10**30.
    function verifyOracleProofV2(
        bytes32 root,
        uint256[2] calldata sigs,
        uint256 committeeId,
        uint256 pairId,
        uint256 price,
        uint256 timestamp
    ) external {
        if (root == bytes32(0)) revert RootIsZero();
        if (merkleSet[root]) revert RootAlreadySeen();

        // requireRootVerified → requireHashVerified_V2
        verifier.requireHashVerified_V2(root, sigs, committeeId);

        merkleSet[root] = true;
        priceOf[pairId] = price;
        updatedAt[pairId] = timestamp;
    }
}

/// @dev Minimal lending pool: deposit SAUCE collateral, borrow USDC against oracle price.
///      Models Bonzo Lend's consumption of the (already-written) Supra feed.
contract MiniBonzoLend {
    MockERC20 public immutable sauce;
    MockERC20 public immutable usdc;
    VulnerablePullOracle public immutable oracle;

    uint256 public constant PAIR_SAUCE_WHBAR = 425;
    /// @dev LTV 80% of reported collateral value (in the same raw units as the feed).
    uint256 public constant LTV_BPS = 8000;
    /// @dev In the incident the feed was HBAR-denominated; for the teaching model we
    ///      treat the raw feed integer as "USDC-equivalent value per 1e18 SAUCE units"
    ///      so a 1e30 price on 250e18 collateral dominates any realistic liquidity.
    ///      Historical: 250 SAUCE + 1e30 feed → multi-million borrow capacity.

    mapping(address => uint256) public sauceCollateral;
    mapping(address => uint256) public usdcDebt;

    constructor(MockERC20 _sauce, MockERC20 _usdc, VulnerablePullOracle _oracle) {
        sauce = _sauce;
        usdc = _usdc;
        oracle = _oracle;
    }

    function depositSauce(uint256 amount) external {
        require(sauce.transferFrom(msg.sender, address(this), amount), "pull");
        sauceCollateral[msg.sender] += amount;
    }

    function collateralValueUSDC(address user) public view returns (uint256) {
        uint256 px = oracle.priceOf(PAIR_SAUCE_WHBAR);
        // value = collateral * price / 1e18  (price is per 1e18 SAUCE)
        return (sauceCollateral[user] * px) / 1e18;
    }

    function maxBorrowUSDC(address user) public view returns (uint256) {
        return (collateralValueUSDC(user) * LTV_BPS) / 10_000;
    }

    function borrowUSDC(uint256 amount) external {
        uint256 debt = usdcDebt[msg.sender] + amount;
        require(debt <= maxBorrowUSDC(msg.sender), "undercollateralized");
        usdcDebt[msg.sender] = debt;
        require(usdc.transfer(msg.sender, amount), "liquidity");
    }
}
