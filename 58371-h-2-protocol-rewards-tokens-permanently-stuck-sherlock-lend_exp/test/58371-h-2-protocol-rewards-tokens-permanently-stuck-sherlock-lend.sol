// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — H-2 (Sherlock 2025-05, issue 184)
    CoreRouter.liquidateSeizeUpdate books 2.8% of seized collateral into
    protocolReward and never pays it out. 1000e18 seized leaves 28e18 stuck.
    Source: Lend-V2/src/LayerZero/CoreRouter.sol liquidateSeizeUpdate.
*/

contract Collateral {
    string public symbol = "COL";
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

contract ExponentialNoError {
    uint256 constant expScale = 1e18;

    struct Exp {
        uint256 mantissa;
    }

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / expScale;
    }

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }
}

contract LendStorage {
    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 2.8e16;
    mapping(address => mapping(address => uint256)) public totalInvestment;
    mapping(address => uint256) public protocolReward;

    function updateProtocolReward(address lToken, uint256 amount) external {
        protocolReward[lToken] = amount;
    }

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function distributeSupplierLend(address, address) external {}
}

contract Lendtroller {
    function liquidateCalculateSeizeTokens(address, address, uint256) external pure returns (uint256, uint256) {
        return (0, 1000e18);
    }
}

contract CoreRouter is ExponentialNoError {
    LendStorage public immutable lendStorage;
    Lendtroller public immutable lendtroller;
    Collateral public immutable collateral;

    constructor(LendStorage lendStorage_, Lendtroller lendtroller_, Collateral collateral_) {
        lendStorage = lendStorage_;
        lendtroller = lendtroller_;
        collateral = collateral_;
    }

    function liquidate(address borrower, address lTokenCollateral, address borrowedlToken, uint256 repayAmount) external {
        liquidateSeizeUpdate(msg.sender, borrower, lTokenCollateral, borrowedlToken, repayAmount);
    }

    function liquidateSeizeUpdate(
        address sender,
        address borrower,
        address lTokenCollateral,
        address borrowedlToken,
        uint256 repayAmount
    ) internal {
        (uint256 amountSeizeError, uint256 seizeTokens) =
            lendtroller.liquidateCalculateSeizeTokens(borrowedlToken, lTokenCollateral, repayAmount);
        require(amountSeizeError == 0, "Failed to calculate");
        require(lendStorage.totalInvestment(borrower, lTokenCollateral) >= seizeTokens, "Insufficient collateral");

        uint256 currentReward = mul_(seizeTokens, Exp({mantissa: lendStorage.PROTOCOL_SEIZE_SHARE_MANTISSA()}));
        if (currentReward >= seizeTokens) {
            currentReward = 0;
        }

        lendStorage.updateProtocolReward(lTokenCollateral, lendStorage.protocolReward(lTokenCollateral) + currentReward); // @> VULN: 2.8% of seized collateral is added to protocolReward, which no function ever pays out

        lendStorage.distributeSupplierLend(lTokenCollateral, sender);
        lendStorage.distributeSupplierLend(lTokenCollateral, borrower);
        lendStorage.updateTotalInvestment(
            borrower, lTokenCollateral, lendStorage.totalInvestment(borrower, lTokenCollateral) - seizeTokens
        );
        lendStorage.updateTotalInvestment(
            sender, lTokenCollateral, lendStorage.totalInvestment(sender, lTokenCollateral) + (seizeTokens - currentReward)
        );
    }

    function redeem(uint256 _amount, address _lToken) external {
        require(_amount > 0, "Zero redeem amount");
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        lendStorage.updateTotalInvestment(msg.sender, _lToken, lendStorage.totalInvestment(msg.sender, _lToken) - _amount);
        collateral.transfer(msg.sender, _amount);
    }
}

contract Exploit {
    address public constant BORROWER = address(0xB0B);
    address public constant LTOKEN = address(0xCA0);

    Collateral public col;
    Lendtroller public lendtroller;
    LendStorage public store;
    CoreRouter public router;
    uint256 public stuck;

    constructor() {
        col = new Collateral();
        lendtroller = new Lendtroller();
        store = new LendStorage();
        router = new CoreRouter(store, lendtroller, col);
    }

    function run() external {
        col.mint(address(router), 1000e18); // STORY: custody
        store.updateTotalInvestment(BORROWER, LTOKEN, 1000e18); // STORY: position
        router.liquidate(BORROWER, LTOKEN, LTOKEN, 1); // STORY: liquidate
        stuck = store.protocolReward(LTOKEN); // STORY: read reward
        uint256 credited = store.totalInvestment(address(this), LTOKEN);
        router.redeem(credited, LTOKEN); // STORY: redeem
        require(stuck == 28e18, "reward");
        require(col.balanceOf(address(router)) == 28e18, "stuck"); // STORY: stranded
        require(col.balanceOf(address(this)) == 972e18, "liquidator");
        require(store.totalInvestment(BORROWER, LTOKEN) == 0, "borrower");
        require(store.totalInvestment(address(this), LTOKEN) == 0, "claim");
    }
}
