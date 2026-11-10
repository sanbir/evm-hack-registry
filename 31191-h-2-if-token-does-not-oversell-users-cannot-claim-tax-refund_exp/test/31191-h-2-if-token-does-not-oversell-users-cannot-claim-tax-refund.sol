// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Zap Protocol TokenSale — tax refund blocked when the sale does not oversell
    (Sherlock 2024-03, H-2). SYNTHETIC, cheatcode-free reduction.

    claim() copies the audited body. `_claim` leaves `left == 0` unless
    totalPrivateSold > totalSupplyInValue. The require(left > 0) then reverts
    before the tax-free refund transfer. A finished, non-oversold stake is
    seeded inside run(): deposit needs epoch Private and claim needs epoch
    Finished, which one timestamp cannot do. The refund math is unchanged. */

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
        return 1000;
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

    /// Post-deposit state: tax already sat in the marketing wallet, sale not oversold.
    function seedUnsold(address investor, uint128 depositScaled, uint256 taxPaid) external {
        stakes[investor] = Staked({amount: depositScaled, share: 0, claimed: false, taxAmount: taxPaid});
        state.totalPrivateSold = depositScaled;
        state.totalSupplyInValue = depositScaled + depositScaled;
        epoch = Epoch.Finished;
        Marketing(marketingWallet).approve(address(usdc), address(this), taxPaid);
        usdc.safeTransferFrom(msg.sender, marketingWallet, taxPaid);
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
        // @> VULN: left is 0 when the sale did not oversell, so this require blocks the tax refund
        require(left > 0, "TokenSale: Nothing to claim");
        uint256 refundTaxAmount;
        if (s.taxAmount > 0) {
            uint256 tax = userTaxRate(s.amount, msg.sender);
            uint256 taxFreeAllc = _maxTaxfreeAllocation(msg.sender) * PCT_BASE;
            if (taxFreeAllc >= s.share) {
                refundTaxAmount = s.taxAmount;
            } else {
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
}

/// Same claim body with the surplus require removed. The tax-free branch pays s.taxAmount.
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
        // FIX: drop require(left > 0). A zero surplus still owes the tax-free refund.
        uint256 refundTaxAmount;
        if (s.taxAmount > 0) {
            uint256 tax = userTaxRate(s.amount, msg.sender);
            uint256 taxFreeAllc = _maxTaxfreeAllocation(msg.sender) * PCT_BASE;
            if (taxFreeAllc >= s.share) {
                refundTaxAmount = s.taxAmount;
            } else {
                refundTaxAmount = (left * tax) / POINT_BASE;
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
    uint256 public constant TAX_REFUND = 100 ether;

    MockUSDC public usdc; // CREATE nonce 1
    MockAdmin public admin; // CREATE nonce 2
    MockStaking public staking; // CREATE nonce 3
    Marketing public marketing; // CREATE nonce 4
    TokenSale public sale; // CREATE nonce 5

    uint256 public stuckRefund;
    uint256 public userReceived;
    bool public claimReverted;

    constructor() {
        usdc = new MockUSDC();
        admin = new MockAdmin();
        staking = new MockStaking();
        marketing = new Marketing();
        sale = new TokenSale(address(usdc), address(admin), address(staking), address(marketing));
    }

    function run() external {
        usdc.mint(address(this), TAX_REFUND);
        usdc.approve(address(sale), type(uint256).max);
        sale.seedUnsold(address(this), uint128(DEPOSIT), TAX_REFUND);
        stuckRefund = usdc.balanceOf(address(marketing));
        require(stuckRefund == TAX_REFUND, "tax not seated");
        (bool ok, bytes memory ret) = address(sale).call(abi.encodeWithSelector(sale.claim.selector));
        claimReverted = !ok;
        require(claimReverted, "claim must revert");
        require(_nothingToClaim(ret), "unexpected revert");
        userReceived = usdc.balanceOf(address(this));
        require(userReceived == 0, "user was paid");
        require(usdc.balanceOf(address(marketing)) == TAX_REFUND, "refund moved");
    }

    function _nothingToClaim(bytes memory ret) internal pure returns (bool) {
        bytes memory expected = abi.encodeWithSignature("Error(string)", "TokenSale: Nothing to claim");
        return keccak256(ret) == keccak256(expected);
    }
}
