// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-03 (Pashov, 2025-05-06)
    DebtToken.mint folds already-indexed interest into the scaled supply, and
    totalSupply() rayMuls that supply by the usage index again. Reported debt
    becomes 4100 while real debt is 2100, so a 400 borrow that still fits under
    the 2500 cap is refused.

    Verbatim lines: totalSupply rayMul, scaledBalanceIncrease, amountToMint.
*/

interface ILendingPool {
    function getNormalizedDebt() external view returns (uint256);
}

library RayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY;
    }

    function toUint128(uint256 a) internal pure returns (uint128) {
        require(a <= type(uint128).max, "u128");
        return uint128(a);
    }
}

contract ERC20Scaled {
    uint256 internal _scaledSupply;
    mapping(address => uint256) public balanceOf;

    function totalSupply() public view virtual returns (uint256) {
        return _scaledSupply;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        _scaledSupply += amount;
    }
}

contract DebtToken is ERC20Scaled {
    using RayMath for uint256;

    address internal _lendingPool;
    mapping(address => uint256) internal userIndex;

    function setLendingPool(address pool) external {
        require(_lendingPool == address(0), "pool set");
        _lendingPool = pool;
    }

    function totalSupply() public view override(ERC20Scaled) returns (uint256) {
        return super.totalSupply().rayMul(ILendingPool(_lendingPool).getNormalizedDebt());
    }

    /// @notice `positionIndex` / `rawDebtBalance` names match the reported mint body.
    function mint(address onBehalfOf, uint256 amountScaled, uint256 poolUsageIndex) public virtual {
        require(msg.sender == _lendingPool, "pool");
        uint256 rawDebtBalance = balanceOf[onBehalfOf];
        uint256 positionIndex = userIndex[onBehalfOf];
        uint256 scaledBalanceIncrease;
        if (positionIndex != 0 && positionIndex < poolUsageIndex) {
            scaledBalanceIncrease = rawDebtBalance.rayMul(poolUsageIndex) - rawDebtBalance.rayMul(positionIndex); // @> VULN: interest already expressed in index units is minted into the scaled supply
        }
        uint256 amountToMint = amountScaled + scaledBalanceIncrease; // @> VULN: totalSupply() rayMuls this sum again, compounding the interest
        // FIX: mint only `amountScaled`. Leave interest inside the usage index.
        _mint(onBehalfOf, uint256(amountToMint.toUint128()));
        userIndex[onBehalfOf] = poolUsageIndex;
    }
}

contract LendingPool is ILendingPool {
    uint256 internal constant RAY = 1e27;

    DebtToken public debt;
    uint256 public index = RAY;
    uint256 public realDebt;
    uint256 public supplyCap = 2500 ether;

    error SupplyCapExceeded();

    constructor(DebtToken _debt) {
        debt = _debt;
    }

    function getNormalizedDebt() external view returns (uint256) {
        return index;
    }

    function accrue(uint256 newIndex) external {
        require(newIndex > index, "index");
        if (realDebt > 0) realDebt = realDebt * newIndex / index;
        index = newIndex;
    }

    function borrow(address user, uint256 amount) external {
        uint256 reported = debt.totalSupply();
        if (reported + amount > supplyCap) revert SupplyCapExceeded();
        uint256 amountScaled = amount * RAY / index;
        debt.mint(user, amountScaled, index);
        realDebt += amount;
    }

    function canBorrow(uint256 amount) external view returns (bool) {
        return debt.totalSupply() + amount <= supplyCap;
    }
}

contract Exploit {
    DebtToken public debt; // CREATE nonce 1
    LendingPool public pool; // CREATE nonce 2

    constructor() {
        debt = new DebtToken();
        pool = new LendingPool(debt);
        debt.setLendingPool(address(pool));
        // 1000 principal at index 1.0. Reported supply equals real debt here.
        pool.borrow(address(this), 1000 ether);
    }

    function run() external {
        pool.accrue(2e27); // index doubles; real debt is 2000 before the new borrow
        pool.borrow(address(this), 100 ether); // mints 1000 of already-indexed interest plus 50 scaled
        uint256 reported = debt.totalSupply();
        require(reported == 4100 ether, "reported supply");
        require(pool.realDebt() == 2100 ether, "real debt");
        require(reported > pool.realDebt(), "not inflated");
        // 2100 + 400 = 2500, equal to the cap. The inflated 4100 blocks it.
        require(pool.realDebt() + 400 ether <= pool.supplyCap(), "real borrow fits");
        require(!pool.canBorrow(400 ether), "inflated supply must deny the borrow");
    }
}
