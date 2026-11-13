// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Finance — excess collateral cannot be withdrawn once the loan is repaid
    (Sigma Prime, finding 26296).
    SYNTHETIC, cheatcode-free. externalUnlockCollateral reverts when the
    repurchase obligation is 0 (@> VULN). After a liquidation that covered the
    debt and left 500 collateral, the borrower cannot take that 500. The
    control pays it. */

contract MockToken {
    string public name = "COLL";
    string public symbol = "COLL";
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

contract Servicer {
    mapping(address => uint256) public obligation;

    function setObligation(address borrower, uint256 amount) external {
        obligation[borrower] = amount;
    }

    function getBorrowerRepurchaseObligation(address borrower) external view returns (uint256) {
        return obligation[borrower];
    }
}

error ZeroBorrowerRepurchaseObligation();

contract TermRepoLocker {
    MockToken public coll;
    Servicer public servicer;

    constructor(address _coll, address _servicer) {
        coll = MockToken(_coll);
        servicer = Servicer(_servicer);
    }

    function externalUnlockCollateral(address borrower, uint256 amount) external {
        // @> VULN: a fully repaid borrower still reverts, so leftover collateral cannot move
        if (servicer.getBorrowerRepurchaseObligation(borrower) == 0) {
            revert ZeroBorrowerRepurchaseObligation();
        }
        coll.transfer(borrower, amount);
    }
}

contract TermRepoLockerFixed {
    MockToken public coll;
    Servicer public servicer;

    constructor(address _coll, address _servicer) {
        coll = MockToken(_coll);
        servicer = Servicer(_servicer);
    }

    function externalUnlockCollateral(address borrower, uint256 amount) external {
        // FIX: obligation 0 after liquidation or default is exactly when excess may leave
        coll.transfer(borrower, amount);
    }
}

contract Exploit {
    MockToken public coll;
    Servicer public servicer;
    TermRepoLocker public locker;
    address public borrower;
    uint256 public constant EXCESS = 500 ether;

    constructor() {
        coll = new MockToken();
        servicer = new Servicer();
        borrower = address(new Receiver());
        locker = new TermRepoLocker(address(coll), address(servicer));
        servicer.setObligation(borrower, 0);
    }

    function run() external {
        coll.mint(address(locker), EXCESS);
        (bool ok,) = address(locker).call(
            abi.encodeWithSelector(locker.externalUnlockCollateral.selector, borrower, EXCESS)
        );
        require(!ok, "unlock reverts");
        require(coll.balanceOf(address(locker)) == EXCESS, "500 stuck");
        require(coll.balanceOf(borrower) == 0, "borrower unpaid");
        require(servicer.getBorrowerRepurchaseObligation(borrower) == 0, "loan repaid");
    }
}

contract Receiver {}
