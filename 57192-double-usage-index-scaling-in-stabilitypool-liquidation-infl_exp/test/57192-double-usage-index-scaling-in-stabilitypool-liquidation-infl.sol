// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC StabilityPool — Codehawks, finding 57192 (Feb 2025)
    getUserDebt already returns principal * usageIndex.
    liquidateBorrower rayMuls that value by getNormalizedDebt again.
    With the report's post-year index, actual debt is ~70511 crvUSD and the
    double-scaled check demands ~99436. The pool holds 80000, so liquidation
    reverts and the NFT stays with the borrower. The control compares the
    pool balance to getUserDebt once and seizes the NFT.
*/

library WadRayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY;
    }
}

error InsufficientBalance();

contract CrvUsd {
    string public symbol = "crvUSD";
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

contract Collateral {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function seize(uint256 id, address from, address to) external {
        require(ownerOf[id] == from, "owner");
        ownerOf[id] = to;
    }
}

contract LendingPool {
    uint256 public normalizedDebt = 1e27;
    mapping(address => uint256) public principal;

    function setNormalizedDebt(uint256 index) external {
        normalizedDebt = index;
    }

    function setPrincipal(address user, uint256 amount) external {
        principal[user] = amount;
    }

    function getNormalizedDebt() external view returns (uint256) {
        return normalizedDebt;
    }

    function getUserDebt(address user) public view returns (uint256) {
        return principal[user] * normalizedDebt / WadRayMath.RAY;
    }
}

contract StabilityPool {
    CrvUsd public crv;
    LendingPool public lendingPool;
    Collateral public collateral;
    bool public seized;
    uint256 public lastUserDebt;
    uint256 public lastScaled;

    constructor(CrvUsd _crv, LendingPool _lendingPool, Collateral _collateral) {
        crv = _crv;
        lendingPool = _lendingPool;
        collateral = _collateral;
    }

    function liquidateBorrower(address userAddress) external {
        uint256 userDebt = lendingPool.getUserDebt(userAddress);
        // @> VULN: getUserDebt is already scaled by the usage index, and rayMul scales it again
        uint256 scaledUserDebt = WadRayMath.rayMul(userDebt, lendingPool.getNormalizedDebt());
        lastUserDebt = userDebt;
        lastScaled = scaledUserDebt;
        uint256 crvUSDBalance = crv.balanceOf(address(this));
        if (crvUSDBalance < scaledUserDebt) revert InsufficientBalance();
        collateral.seize(1, userAddress, address(this));
        seized = true;
    }

    function liquidateBorrowerFixed(address userAddress) external {
        uint256 userDebt = lendingPool.getUserDebt(userAddress);
        uint256 crvUSDBalance = crv.balanceOf(address(this));
        require(crvUSDBalance >= userDebt, "short");
        collateral.seize(1, userAddress, address(this));
        seized = true;
    }
}

contract Exploit {
    uint256 public constant INDEX = 1410226029899202994928355252;
    uint256 public constant PRINCIPAL = 50_000 ether;
    uint256 public constant POOL_BALANCE = 80_000 ether;
    address public borrower;

    CrvUsd public crv;
    Collateral public collateral;
    LendingPool public lendingPool;
    StabilityPool public pool;
    bool public liquidateReverted;
    uint256 public actualDebt;
    uint256 public doubleScaled;
    uint256 public poolBal;

    constructor() {
        borrower = address(new Borrower());
        crv = new CrvUsd();
        collateral = new Collateral();
        lendingPool = new LendingPool();
        pool = new StabilityPool(crv, lendingPool, collateral);
        lendingPool.setNormalizedDebt(INDEX);
        lendingPool.setPrincipal(borrower, PRINCIPAL);
        collateral.mint(borrower, 1);
        crv.mint(address(pool), POOL_BALANCE);
    }

    function run() external {
        actualDebt = lendingPool.getUserDebt(borrower);
        try pool.liquidateBorrower(borrower) {
            liquidateReverted = false;
        } catch {
            liquidateReverted = true;
        }
        doubleScaled = WadRayMath.rayMul(actualDebt, lendingPool.getNormalizedDebt());
        poolBal = crv.balanceOf(address(pool));
        require(liquidateReverted, "reverted");
        require(!pool.seized(), "seized");
        require(collateral.ownerOf(1) == borrower, "nft");
        require(actualDebt < poolBal, "covers actual");
        require(poolBal < doubleScaled, "below double");
        require(poolBal == POOL_BALANCE, "untouched");
    }
}

contract Borrower {}
