// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Zap Protocol TokenSale — tax refund uses the wrong base
    (Sherlock 2024-03, H-1). SYNTHETIC, cheatcode-free reduction.

    claim() copies the audited body. When share exceeds the tax-free
    allocation, the refund is (left * tax) / POINT_BASE. The report's
    example is a 1,000 USDC deposit oversold to a 500 USDC share and a
    500 USDC left, with a 400 USDC tax-free allocation. At a 10% rate
    the paid refund is 50 USDC. The corrected base (left + tax-free)
    pays 90 USDC. The 40 USDC gap stays in the marketing wallet.

    Deposit needs epoch Private and claim needs epoch Finished, which
    one timestamp cannot do. The finished oversold stake is seeded
    inside run(). No warp. */

contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function safeTransfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "USDC: allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockAdmin {
    function blockClaim(address) external pure returns (bool) {
        return false;
    }
}

/// Tax-free allocation in whole dollars. claim() multiplies by PCT_BASE.
contract MockStaking {
    function getAllocationOf(address) external pure returns (uint256) {
        return 400;
    }
}

contract Marketing {
    function approve(address token, address spender, uint256 amount) external {
        MockUSDC(token).approve(spender, amount);
    }
}

contract TokenSale {
    uint256 constant PCT_BASE = 10 ** 18;
    uint256 constant POINT_BASE = 1000;

    enum Epoch {
        Incoming,
        Private,
        Finished
    }

    struct Staked {
        uint128 amount;
        uint120 share;
        bool claimed;
        uint256 taxAmount;
    }

    struct Params {
        uint96 totalSupply;
        uint32 privateStart;
        uint96 privateTokenPrice;
        uint32 privateEnd;
    }

    struct State {
        uint128 totalPrivateSold;
        uint128 totalSupplyInValue;
    }

    event Claim(address indexed user, uint256 change);

    MockUSDC public usdc;
    MockAdmin public admin;
    MockStaking public staking;
    address public marketingWallet;
    Epoch public epoch;
    Params params;
    State state;
    uint256 public globalTaxRate;
    uint256 public whitelistTxRate;
    mapping(address => Staked) public stakes;
    mapping(address => uint256) public tokensaleTiers;
    mapping(address => bool) public isWhitelisted;

    constructor(address _usdc, address _admin, address _staking, address _marketing) {
        usdc = MockUSDC(_usdc);
        admin = MockAdmin(_admin);
        staking = MockStaking(_staking);
        marketingWallet = _marketing;
        globalTaxRate = 100;
        params.privateStart = 0;
        params.privateEnd = 0;
    }

    function checkingEpoch() public {
        uint256 time = block.timestamp;
        if (epoch != Epoch.Private && time >= params.privateStart && time <= params.privateEnd) {
            epoch = Epoch.Private;
            return;
        }
        if ((epoch != Epoch.Finished && (time > params.privateEnd))) {
            epoch = Epoch.Finished;
            return;
        }
    }

    /// Post-deposit state: 10% tax already paid, sale oversold 2:1, left funded.
    function seedOversold(address investor, uint128 depositScaled, uint256 taxPaid, uint256 leftFund) external {
        stakes[investor] = Staked({amount: depositScaled, share: 0, claimed: false, taxAmount: taxPaid});
        state.totalPrivateSold = depositScaled + depositScaled;
        state.totalSupplyInValue = depositScaled;
        epoch = Epoch.Finished;
        Marketing(marketingWallet).approve(address(usdc), address(this), taxPaid);
        usdc.safeTransferFrom(msg.sender, marketingWallet, taxPaid);
        usdc.safeTransferFrom(msg.sender, address(this), leftFund);
    }

    function userTaxRate(uint256 _amount, address _sender) public returns (uint256) {
        uint256 userTaxFreeAllc = 0;
        if (_amount > userTaxFreeAllc) {
            if (isWhitelisted[_sender]) {
                return whitelistTxRate;
            } else {
                return globalTaxRate;
            }
        } else {
            return 0;
        }
    }

    function _maxTaxfreeAllocation(address _sender) internal returns (uint256) {
        uint256 userTierAllc = staking.getAllocationOf(_sender);
        uint256 giftedTierAllc = tokensaleTiers[_sender];
        if (userTierAllc > giftedTierAllc) {
            return userTierAllc;
        } else {
            return giftedTierAllc;
        }
    }

    function claim() external virtual {
        checkingEpoch();
        require(uint8(epoch) > 1 && !admin.blockClaim(address(this)), "TokenSale: Not time or not allowed");

        Staked storage s = stakes[msg.sender];
        require(s.amount != 0, "TokenSale: No Deposit");
        require(!s.claimed, "TokenSale: Already Claimed");

        uint256 left;
        (s.share, left) = _claim(s);
        require(left > 0, "TokenSale: Nothing to claim");
        uint256 refundTaxAmount;
        if (s.taxAmount > 0) {
            uint256 tax = userTaxRate(s.amount, msg.sender);
            uint256 taxFreeAllc = _maxTaxfreeAllocation(msg.sender) * PCT_BASE;
            if (taxFreeAllc >= s.share) {
                refundTaxAmount = s.taxAmount;
            } else {
                // @> VULN: base is only left, so the 400 USDC tax-free allocation is omitted
                refundTaxAmount = (left * tax) / POINT_BASE;
            }
            usdc.safeTransferFrom(marketingWallet, msg.sender, refundTaxAmount);
        }
        s.claimed = true;
        usdc.safeTransfer(msg.sender, left);
        emit Claim(msg.sender, left);
    }

    function _claim(Staked memory _s) internal view returns (uint120, uint256) {
        uint256 left;
        if (state.totalPrivateSold > (state.totalSupplyInValue)) {
            uint256 rate = (state.totalSupplyInValue * PCT_BASE) / state.totalPrivateSold;
            _s.share = uint120((uint256(_s.amount) * rate) / PCT_BASE);
            left = uint256(_s.amount) - uint256(_s.share);
        } else {
            _s.share = uint120(_s.amount);
        }
        return (_s.share, left);
    }

    function canClaim(address _user) external view returns (uint120, uint256) {
        return _claim(stakes[_user]);
    }
}

/// Same claim body. The refund base is left plus the tax-free allocation.
contract TokenSaleFixed is TokenSale {
    constructor(address _usdc, address _admin, address _staking, address _marketing)
        TokenSale(_usdc, _admin, _staking, _marketing)
    {}

    function claim() external override {
        checkingEpoch();
        require(uint8(epoch) > 1 && !admin.blockClaim(address(this)), "TokenSale: Not time or not allowed");

        Staked storage s = stakes[msg.sender];
        require(s.amount != 0, "TokenSale: No Deposit");
        require(!s.claimed, "TokenSale: Already Claimed");

        uint256 left;
        (s.share, left) = _claim(s);
        require(left > 0, "TokenSale: Nothing to claim");
        uint256 refundTaxAmount;
        if (s.taxAmount > 0) {
            uint256 tax = userTaxRate(s.amount, msg.sender);
            uint256 taxFreeAllc = _maxTaxfreeAllocation(msg.sender) * PCT_BASE;
            if (taxFreeAllc >= s.share) {
                refundTaxAmount = s.taxAmount;
            } else {
                // FIX: add the tax-free allocation back into the refund base
                refundTaxAmount = ((left + taxFreeAllc) * tax) / POINT_BASE;
            }
            usdc.safeTransferFrom(marketingWallet, msg.sender, refundTaxAmount);
        }
        s.claimed = true;
        usdc.safeTransfer(msg.sender, left);
        emit Claim(msg.sender, left);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1000 ether;
    uint256 public constant LEFT = 500 ether;
    uint256 public constant TAX_FREE = 400 ether;
    uint256 public constant TAX_RATE = 100;
    uint256 public constant TAX_PAID = 100 ether;
    uint256 public constant PAID_REFUND = 50 ether;
    uint256 public constant FAIR_REFUND = 90 ether;
    uint256 public constant SHORTFALL = 40 ether;

    MockUSDC public usdc; // CREATE nonce 1
    MockAdmin public admin; // CREATE nonce 2
    MockStaking public staking; // CREATE nonce 3
    Marketing public marketing; // CREATE nonce 4
    TokenSale public sale; // CREATE nonce 5

    uint256 public paidRefund;
    uint256 public fairRefund;
    uint256 public shortfall;
    uint256 public retained;

    constructor() {
        usdc = new MockUSDC();
        admin = new MockAdmin();
        staking = new MockStaking();
        marketing = new Marketing();
        sale = new TokenSale(address(usdc), address(admin), address(staking), address(marketing));
    }

    function run() external {
        usdc.mint(address(this), TAX_PAID + LEFT);
        usdc.approve(address(sale), type(uint256).max);
        sale.seedOversold(address(this), uint128(DEPOSIT), TAX_PAID, LEFT);
        require(usdc.balanceOf(address(marketing)) == TAX_PAID, "tax not seated");
        require(usdc.balanceOf(address(sale)) == LEFT, "left not seated");
        require(usdc.balanceOf(address(this)) == 0, "investor not emptied");
        (uint120 share, uint256 left) = sale.canClaim(address(this));
        require(share == uint120(LEFT) && left == LEFT, "split");
        uint256 taxFree = staking.getAllocationOf(address(this)) * 1 ether;
        require(taxFree == TAX_FREE, "tax-free allocation");
        sale.claim();
        retained = usdc.balanceOf(address(marketing));
        paidRefund = TAX_PAID - retained;
        fairRefund = ((LEFT + TAX_FREE) * sale.globalTaxRate()) / 1000;
        shortfall = fairRefund - paidRefund;
        require(paidRefund == PAID_REFUND, "paid refund");
        require(fairRefund == FAIR_REFUND, "fair refund");
        require(shortfall == SHORTFALL, "shortfall");
        require(usdc.balanceOf(address(this)) == LEFT + paidRefund, "investor proceeds");
    }
}
