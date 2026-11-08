// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Astrolab As4626 — previewDeposit fees the caller, _deposit fees the receiver
    (Pashov, H-06, #58103). January 2024 review of AstrolabDAO/strats.
    SYNTHETIC, cheatcode-free.
    Entry fee is 10%. An exempt seed of 9,000 assets sits in the vault.
    A non-exempt caller pays X = 10,000 to an exempt receiver.
    previewDeposit (msg.sender) mints 9,000 shares, the shares a fee-free
    deposit of Y = 9,000 would mint. The receiver's own preview quotes 10,000.
    _deposit looks at the exempt receiver and books claimableAssetFees = 0.
    The 9,000 shares are worth 9,500 of the 19,000 assets now in the vault,
    so the depositor is short 500 versus the 10,000 they paid.
    Control uses msg.sender for the fee ledger too, so the haircut is booked. */

contract Asset {
    string public constant name = "Asset";
    string public constant symbol = "AST";
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

contract Vault {
    uint256 public constant BP = 10_000;
    uint256 public constant ENTRY = 1_000;

    Asset public immutable asset;
    uint256 public totalSupply;
    uint256 public claimableAssetFees;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public exemptionList;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function setExempt(address who, bool exempt) external {
        exemptionList[who] = exempt;
    }

    function subBp(uint256 amount, uint256 bps) public pure returns (uint256) {
        return amount * (BP - bps) / BP;
    }

    function revBp(uint256 amount, uint256 bps) public pure returns (uint256) {
        return amount * bps / (BP - bps);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return assets * supply / asset.balanceOf(address(this));
    }

    function previewDeposit(uint256 _amount) public view returns (uint256 shares) {
        uint256 gross = convertToShares(_amount);
        if (exemptionList[msg.sender]) {
            return gross;
        }
        // FIX: price this fee off the same account _deposit uses.
        shares = subBp(gross, ENTRY); // @> VULN: entry fee is priced off msg.sender, not the receiver
    }

    /// @dev Verbatim target from As4626._deposit. FIX: exemptionList[msg.sender].
    function _deposit(uint256 _amount, uint256 _shares, address _receiver) internal returns (uint256) {
        asset.transferFrom(msg.sender, address(this), _amount);
        if (!exemptionList[_receiver]) {
            claimableAssetFees += revBp(_amount, ENTRY);
        }
        balanceOf[_receiver] += _shares;
        totalSupply += _shares;
        return _shares;
    }

    function deposit(uint256 _amount, address _receiver) external returns (uint256 shares) {
        shares = previewDeposit(_amount);
        shares = _deposit(_amount, shares, _receiver);
    }
}

contract VaultFixed {
    uint256 public constant BP = 10_000;
    uint256 public constant ENTRY = 1_000;

    Asset public immutable asset;
    uint256 public totalSupply;
    uint256 public claimableAssetFees;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public exemptionList;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function setExempt(address who, bool exempt) external {
        exemptionList[who] = exempt;
    }

    function subBp(uint256 amount, uint256 bps) public pure returns (uint256) {
        return amount * (BP - bps) / BP;
    }

    function revBp(uint256 amount, uint256 bps) public pure returns (uint256) {
        return amount * bps / (BP - bps);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return assets * supply / asset.balanceOf(address(this));
    }

    function previewDeposit(uint256 _amount) public view returns (uint256 shares) {
        uint256 gross = convertToShares(_amount);
        uint256 bps = exemptionList[msg.sender] ? 0 : ENTRY;
        shares = subBp(gross, bps);
    }

    function _deposit(uint256 _amount, uint256 _shares, address _receiver) internal returns (uint256) {
        asset.transferFrom(msg.sender, address(this), _amount);
        if (!exemptionList[msg.sender]) {
            claimableAssetFees += revBp(_amount, ENTRY);
        }
        balanceOf[_receiver] += _shares;
        totalSupply += _shares;
        return _shares;
    }

    function deposit(uint256 _amount, address _receiver) external returns (uint256 shares) {
        shares = previewDeposit(_amount);
        shares = _deposit(_amount, shares, _receiver);
    }
}

contract ExemptAccount {
    function seed(Asset token, Vault vault, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    function seedFixed(Asset token, VaultFixed vault, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    function quote(Vault vault, uint256 amount) external view returns (uint256) {
        return vault.previewDeposit(amount);
    }
}

contract Exploit {
    uint256 public constant PAID = 10_000 ether;
    uint256 public constant PRICED_AS = 9_000 ether;
    uint256 public constant SEED = 9_000 ether;
    uint256 public constant POSITION = 9_500 ether;

    Asset public asset;
    Vault public vault;
    ExemptAccount public exempt;
    uint256 public sharesMinted;
    uint256 public receiverQuote;
    uint256 public positionValue;
    uint256 public feesBooked;

    constructor() {
        asset = new Asset();
        vault = new Vault(asset);
        exempt = new ExemptAccount();
        vault.setExempt(address(exempt), true);
        asset.mint(address(this), SEED + PAID);
        asset.approve(address(exempt), SEED);
        exempt.seed(asset, vault, SEED);
    }

    function run() external {
        receiverQuote = exempt.quote(vault, PAID);
        require(receiverQuote == PAID, "exempt preview");

        asset.approve(address(vault), PAID);
        sharesMinted = vault.deposit(PAID, address(exempt));
        require(sharesMinted == PRICED_AS, "shares priced as 9000");

        feesBooked = vault.claimableAssetFees();
        require(feesBooked == 0, "fee ledger booked the haircut");

        uint256 assetsNow = asset.balanceOf(address(vault));
        require(assetsNow == SEED + PAID, "paid 10000");
        positionValue = sharesMinted * assetsNow / vault.totalSupply();
        require(positionValue == POSITION, "position worth 9500");
        require(positionValue < PAID, "no shortfall");
    }
}
