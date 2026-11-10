// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Term Finance — reopenToNewAuction does not grant AUCTION_LOCKER
    (Sigma Prime, April 2023, TRM-10).
    SYNTHETIC, cheatcode-free. The new auction is linked and then a bidder
    escrows 4,000 collateral. complete() and refund() both call the
    collateral manager, which allows only AUCTION_LOCKER. Both revert, so
    the 4,000 stays in the auction. The control grants the role and the
    auction completes. */

contract CollateralToken {
    string public constant symbol = "COLL";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IManager {
    function auctionLockCollateral(address sender, address token, uint256 amount) external;
    function auctionUnlockCollateral(address sender, address token, uint256 amount) external;
}

contract CollateralManager is IManager {
    bytes32 public constant AUCTION_LOCKER = keccak256("AUCTION_LOCKER");
    bytes32 public constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");

    mapping(bytes32 => mapping(address => bool)) public hasRole;
    address public currentAuction;

    constructor() {
        hasRole[DEFAULT_ADMIN_ROLE][msg.sender] = true;
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole[role][msg.sender], "missing role");
        _;
    }

    /// @notice Audited reopen path. The report's fix grants AUCTION_LOCKER here.
    function reopenToNewAuction(address auction) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // @> VULN: the new auction is linked and never receives AUCTION_LOCKER
        currentAuction = auction;
    }

    function auctionLockCollateral(address, address, uint256) external onlyRole(AUCTION_LOCKER) {}

    function auctionUnlockCollateral(address, address, uint256) external onlyRole(AUCTION_LOCKER) {}
}

contract CollateralManagerFixed is IManager {
    bytes32 public constant AUCTION_LOCKER = keccak256("AUCTION_LOCKER");
    bytes32 public constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");

    mapping(bytes32 => mapping(address => bool)) public hasRole;
    address public currentAuction;

    constructor() {
        hasRole[DEFAULT_ADMIN_ROLE][msg.sender] = true;
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole[role][msg.sender], "missing role");
        _;
    }

    function reopenToNewAuction(address auction) external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentAuction = auction;
        hasRole[AUCTION_LOCKER][auction] = true;
    }

    function auctionLockCollateral(address, address, uint256) external onlyRole(AUCTION_LOCKER) {}

    function auctionUnlockCollateral(address, address, uint256) external onlyRole(AUCTION_LOCKER) {}
}

contract TermAuction {
    IManager public cm;
    CollateralToken public token;
    uint256 public escrow;
    bool public completed;

    constructor(IManager cm_, CollateralToken token_) {
        cm = cm_;
        token = token_;
    }

    function lockBid(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        escrow += amount;
    }

    function complete() external {
        cm.auctionLockCollateral(address(this), address(token), escrow);
        token.transfer(address(cm), escrow);
        escrow = 0;
        completed = true;
    }

    function refund(address to) external {
        cm.auctionUnlockCollateral(address(this), address(token), escrow);
        token.transfer(to, escrow);
        escrow = 0;
    }
}

contract Exploit {
    uint256 internal constant AMOUNT = 4_000 ether;

    CollateralToken public token;
    CollateralManager public manager;
    TermAuction public auction;
    bool public completeReverted;
    bool public refundReverted;
    uint256 public stuck;

    function run() external {
        token = new CollateralToken(); // nonce 1
        manager = new CollateralManager(); // nonce 2
        auction = new TermAuction(manager, token); // nonce 3

        token.mint(address(this), AMOUNT);
        manager.reopenToNewAuction(address(auction));
        token.approve(address(auction), AMOUNT);
        auction.lockBid(AMOUNT);

        try auction.complete() {} catch {
            completeReverted = true;
        }
        try auction.refund(address(this)) {} catch {
            refundReverted = true;
        }

        stuck = token.balanceOf(address(auction));
        require(completeReverted, "complete succeeded");
        require(refundReverted, "refund succeeded");
        require(stuck == AMOUNT, "not stuck");
        require(!auction.completed(), "completed");
    }
}
