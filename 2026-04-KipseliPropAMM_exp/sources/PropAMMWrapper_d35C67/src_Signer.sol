// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Secp256k1Signer
/// @notice Educational / niche-use secp256k1 ECDSA signer implemented in Solidity.
/// @dev Extremely expensive onchain. Private keys stored onchain are public.
///      Do NOT use for real funds.
library Secp256k1Signer {
    // secp256k1 field prime
    uint256 internal constant P =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    // curve order
    uint256 internal constant N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 internal constant HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // Generator G
    uint256 internal constant GX =
        55066263022277343669578718895168534326250603453777594175500187360389116729240;
    uint256 internal constant GY =
        32670510020758816978083085130507043184471273380659243275938904335757337482424;

    struct Point {
        uint256 x;
        uint256 y;
    }

    error InvalidPrivateKey();
    error ModExpFailed();
    error BadNonce();
    error PointNotOnCurve();

    function sign(bytes32 digest, uint256 privKey)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        if (privKey == 0 || privKey >= N) revert InvalidPrivateKey();

        uint256 z = uint256(digest);
        if (z >= N) {
            z -= N;
        }

        uint256 k;
        uint256 rr;
        uint256 ss;
        uint8 recid;

        // Retry until we get nonzero r,s.
        for (uint256 ctr = 0; ctr < 32; ctr++) {
            k = _deriveNonce(privKey, digest, ctr);
            if (k == 0 || k >= N) continue;

            (Point memory R, uint8 yParity, bool xOverflowedN) =
                _scalarMulWithRecovery(k, Point(GX, GY));

            rr = R.x % N;
            if (rr == 0) continue;

            uint256 kinv = _invMod(k, N);

            // s = k^-1 * (z + r*d) mod n
            uint256 rd = mulmod(rr, privKey, N);
            uint256 sum = addmod(z, rd, N);
            ss = mulmod(kinv, sum, N);
            if (ss == 0) continue;

            recid = yParity | (xOverflowedN ? 2 : 0);

            // Ethereum low-s normalization
            if (ss > HALF_N) {
                ss = N - ss;
                recid ^= 1;
            }

            v = uint8(27 + recid);
            r = bytes32(rr);
            s = bytes32(ss);
            return (v, r, s);
        }

        revert BadNonce();
    }

    function signWithNonce(bytes32 digest, uint256 privKey, uint256 k)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        if (privKey == 0 || privKey >= N) revert InvalidPrivateKey();
        if (k == 0 || k >= N) revert BadNonce();

        uint256 z = uint256(digest);
        if (z >= N) {
            z -= N;
        }

        (Point memory R, uint8 yParity, bool xOverflowedN) =
            _scalarMulWithRecovery(k, Point(GX, GY));

        uint256 rr = R.x % N;
        require(rr != 0, "r=0");

        uint256 kinv = _invMod(k, N);
        uint256 rd = mulmod(rr, privKey, N);
        uint256 ss = mulmod(kinv, addmod(z, rd, N), N);
        require(ss != 0, "s=0");

        uint8 recid = yParity | (xOverflowedN ? 2 : 0);

        if (ss > HALF_N) {
            ss = N - ss;
            recid ^= 1;
        }

        v = uint8(27 + recid);
        r = bytes32(rr);
        s = bytes32(ss);
    }

    function pubkey(uint256 privKey) internal view returns (uint256 x, uint256 y) {
        if (privKey == 0 || privKey >= N) revert InvalidPrivateKey();
        Point memory Q = _scalarMul(privKey, Point(GX, GY));
        return (Q.x, Q.y);
    }

    function addr(uint256 privKey) internal view returns (address) {
        (uint256 x, uint256 y) = pubkey(privKey);
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x == 0 && y == 0) return false;
        if (x >= P || y >= P) return false;
        // y^2 = x^3 + 7 mod p
        uint256 lhs = mulmod(y, y, P);
        uint256 x2 = mulmod(x, x, P);
        uint256 x3 = mulmod(x2, x, P);
        uint256 rhs = addmod(x3, 7, P);
        return lhs == rhs;
    }

    // ============================================================
    // Internal math
    // ============================================================

    function _deriveNonce(uint256 privKey, bytes32 digest, uint256 ctr)
        private
        pure
        returns (uint256)
    {
        // Public, deterministic nonce derivation. Not RFC6979.
        // Fine only because user explicitly accepts exposed key material.
        return uint256(keccak256(abi.encodePacked(privKey, digest, ctr))) % (N - 1) + 1;
    }

    function _scalarMul(uint256 k, Point memory p)
        private
        view
        returns (Point memory r)
    {
        // Double-and-add in affine coordinates.
        // Extremely expensive because doubling/addition each use modular inverse.
        r = Point(0, 0); // infinity
        Point memory addend = p;

        while (k != 0) {
            if (k & 1 != 0) {
                r = _ecAdd(r, addend);
            }
            k >>= 1;
            if (k != 0) {
                addend = _ecDouble(addend);
            }
        }
    }

    function _scalarMulWithRecovery(uint256 k, Point memory p)
        private
        view
        returns (Point memory r, uint8 yParity, bool xOverflowedN)
    {
        r = _scalarMul(k, p);
        if (!isOnCurve(r.x, r.y)) revert PointNotOnCurve();

        yParity = uint8(r.y & 1);
        xOverflowedN = r.x >= N;
    }

    function _ecAdd(Point memory a, Point memory b)
        private
        view
        returns (Point memory)
    {
        // Handle infinity
        if (_isInfinity(a)) return b;
        if (_isInfinity(b)) return a;

        if (a.x == b.x) {
            if (a.y == b.y) {
                return _ecDouble(a);
            } else {
                return Point(0, 0); // infinity
            }
        }

        uint256 lambda = mulmod(
            _modSub(b.y, a.y, P),
            _invMod(_modSub(b.x, a.x, P), P),
            P
        );

        uint256 xr = _modSub(_modSub(mulmod(lambda, lambda, P), a.x, P), b.x, P);
        uint256 yr = _modSub(mulmod(lambda, _modSub(a.x, xr, P), P), a.y, P);

        return Point(xr, yr);
    }

    function _ecDouble(Point memory a)
        private
        view
        returns (Point memory)
    {
        if (_isInfinity(a)) return a;
        if (a.y == 0) return Point(0, 0); // infinity

        // lambda = (3*x^2) / (2*y) mod p
        uint256 x2 = mulmod(a.x, a.x, P);
        uint256 numerator = mulmod(3, x2, P);
        uint256 denominator = mulmod(2, a.y, P);
        uint256 lambda = mulmod(numerator, _invMod(denominator, P), P);

        uint256 xr = _modSub(mulmod(lambda, lambda, P), mulmod(2, a.x, P), P);
        uint256 yr = _modSub(mulmod(lambda, _modSub(a.x, xr, P), P), a.y, P);

        return Point(xr, yr);
    }

    function _isInfinity(Point memory p) private pure returns (bool) {
        return p.x == 0 && p.y == 0;
    }

    function _modSub(uint256 a, uint256 b, uint256 m)
        private
        pure
        returns (uint256)
    {
        unchecked {
            return a >= b ? a - b : m - ((b - a) % m);
        }
    }

    function _invMod(uint256 a, uint256 m)
        private
        view
        returns (uint256)
    {
        require(a != 0 && a < m, "inv input");

        // Fermat inverse: a^(m-2) mod m
        // Valid because both P and N are prime in secp256k1.
        return _modExp(a, m - 2, m);
    }

    function _modExp(uint256 base, uint256 exponent, uint256 modulus)
        private
        view
        returns (uint256 result)
    {
        bytes memory input = abi.encodePacked(
            uint256(32),
            uint256(32),
            uint256(32),
            base,
            exponent,
            modulus
        );

        bytes memory output = new bytes(32);
        bool ok;

        assembly {
            ok := staticcall(
                gas(),
                0x05,
                add(input, 0x20),
                mload(input),
                add(output, 0x20),
                32
            )
        }

        if (!ok) revert ModExpFailed();
        result = abi.decode(output, (uint256));
    }
}


contract Signer {
    using Secp256k1Signer for bytes32;
    uint immutable secretPk;

    constructor(uint _pk) {
        secretPk = _pk;
    }

    function sign(bytes32 digest, uint256 privKey)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return Secp256k1Signer.sign(digest, privKey);
    }

    function signerAddress(uint256 privKey) internal view returns (address) {
        return Secp256k1Signer.addr(privKey);
    }

    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, hex"19_01")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }

    function generateQuoteSignature(address tokenIn, uint /* amountIn */, address tokenOut, uint timestampInMili) public view returns(bytes memory) {
        uint pk = secretPk;
        bytes32 structHash = keccak256(abi.encode(bytes32(0xd9bf8409a9410d5526f0c42a27688ba0538606cc6954e762341896f904d21f72), tokenIn, tokenOut, timestampInMili));
        bytes32 domainSeperator = bytes32(0x2baf010e6ceb7b3df0823603646fac8e961f18c0554d36931aeb693fdc9dec55);

        bytes32 digest = toTypedDataHash(domainSeperator, structHash);

        (uint8 vv, bytes32 r, bytes32 s) = sign(digest, pk);

        bytes memory sig = abi.encodePacked(r, s, vv); // 65 bytes: r||s||v

        return sig;
    }    
}