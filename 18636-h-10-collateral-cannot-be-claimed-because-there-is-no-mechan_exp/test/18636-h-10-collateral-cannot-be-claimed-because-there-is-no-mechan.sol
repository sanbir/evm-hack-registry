// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GMX Synthetics — H-10 claimable collateral cannot be claimed
    (Sherlock 2023-02-gmx, finding 18636).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: MarketUtils.claimCollateral pays
    Precision.applyFactor(claimableAmount, claimableFactor), and the factor
    in DataStore defaults to 0. Config._initAllowedBaseKeys never allows
    CLAIMABLE_COLLATERAL_FACTOR, so the config keeper's setUint reverts
    InvalidBaseKey. The audited comparison then sees adjusted == claimed == 0
    and reverts CollateralAlreadyClaimed. The 1000 USDC recorded for the
    trader stays in the market.

    The audited comparison is `>=` (MarketUtils.sol L632). That direction
    also reverts when the factor is 100% (issue #136). The control therefore
    does both things the later code does: allow the factor key (H-10) and
    compare with `<=`. The keeper sets the factor to 1e30 and the trader
    is paid the 1000 USDC. */

library Keys {
    // Verbatim constants and key builders from gmx-synthetics/contracts/data/Keys.sol.
    bytes32 public constant CLAIMABLE_COLLATERAL_AMOUNT = keccak256(abi.encode("CLAIMABLE_COLLATERAL_AMOUNT"));
    bytes32 public constant CLAIMABLE_COLLATERAL_FACTOR = keccak256(abi.encode("CLAIMABLE_COLLATERAL_FACTOR"));
    bytes32 public constant CLAIMED_COLLATERAL_AMOUNT = keccak256(abi.encode("CLAIMED_COLLATERAL_AMOUNT"));
    bytes32 public constant MIN_COLLATERAL_FACTOR = keccak256(abi.encode("MIN_COLLATERAL_FACTOR"));
    bytes32 public constant MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER =
        keccak256(abi.encode("MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER"));
    bytes32 public constant MIN_COLLATERAL_USD = keccak256(abi.encode("MIN_COLLATERAL_USD"));
    bytes32 public constant VIRTUAL_TOKEN_ID = keccak256(abi.encode("VIRTUAL_TOKEN_ID"));
    bytes32 public constant VIRTUAL_MARKET_ID = keccak256(abi.encode("VIRTUAL_MARKET_ID"));
    bytes32 public constant VIRTUAL_INVENTORY_FOR_SWAPS = keccak256(abi.encode("VIRTUAL_INVENTORY_FOR_SWAPS"));
    bytes32 public constant POSITION_FEE_FACTOR = keccak256(abi.encode("POSITION_FEE_FACTOR"));

    function claimableCollateralAmountKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CLAIMABLE_COLLATERAL_AMOUNT, market, token, timeKey, account));
    }

    function claimableCollateralFactorKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CLAIMABLE_COLLATERAL_FACTOR, market, token, timeKey, account));
    }

    function claimedCollateralAmountKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CLAIMED_COLLATERAL_AMOUNT, market, token, timeKey, account));
    }
}

library Precision {
    // Verbatim from gmx-synthetics/contracts/utils/Precision.sol (audited tree).
    uint256 public constant FLOAT_PRECISION = 10 ** 30;
    uint256 public constant SCALING_FACTOR_TO_AVOID_OVERFLOW = 10 ** 20;
    uint256 public constant FLOAT_PRECISION_AFTER_SCALING_FACTOR = FLOAT_PRECISION / SCALING_FACTOR_TO_AVOID_OVERFLOW;

    function applyFactor(uint256 value, uint256 factor) internal pure returns (uint256) {
        (bool ok, uint256 numerator) = _tryMul(value, factor);
        if (ok) {
            return numerator / FLOAT_PRECISION;
        }

        (uint256 a, uint256 b) = value > factor ? (value, factor) : (factor, value);
        return ((a / SCALING_FACTOR_TO_AVOID_OVERFLOW) * b) / FLOAT_PRECISION_AFTER_SCALING_FACTOR;
    }

    function _tryMul(uint256 a, uint256 b) private pure returns (bool, uint256) {
        if (a == 0 || b == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }
}

contract CollateralToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DataStore {
    mapping(bytes32 => uint256) public uintValues;

    function getUint(bytes32 key) external view returns (uint256) {
        return uintValues[key];
    }

    function setUint(bytes32 key, uint256 value) external {
        uintValues[key] = value;
    }
}

contract MarketBank {
    error CollateralAlreadyClaimed(uint256 adjustedClaimableAmount, uint256 claimedAmount);

    DataStore public immutable dataStore;
    CollateralToken public immutable collateral;
    uint256 public recorded;

    constructor(DataStore store, CollateralToken token) {
        dataStore = store;
        collateral = token;
    }

    function claimErrorSelector() external pure returns (bytes4) {
        return CollateralAlreadyClaimed.selector;
    }

    // Capped positive price impact is recorded as claimable collateral and the
    // tokens are escrowed in the market. This is the state claimCollateral reads.
    function credit(address account, uint256 timeKey, uint256 amount) external {
        address market = address(this);
        bytes32 amountKey = Keys.claimableCollateralAmountKey(market, address(collateral), timeKey, account);
        uint256 next = dataStore.getUint(amountKey) + amount;
        dataStore.setUint(amountKey, next);
        recorded = next;
        collateral.mint(market, amount);
    }

    // MarketUtils.claimCollateral, audited body. `market` is this contract.
    function claimCollateral(address market, address token, uint256 timeKey, address account, address receiver)
        external
        returns (uint256)
    {
        require(market == address(this), "market");
        uint256 claimableAmount = dataStore.getUint(Keys.claimableCollateralAmountKey(market, token, timeKey, account));
        uint256 claimableFactor = dataStore.getUint(Keys.claimableCollateralFactorKey(market, token, timeKey, account));
        uint256 claimedAmount = dataStore.getUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account));

        uint256 adjustedClaimableAmount = Precision.applyFactor(claimableAmount, claimableFactor);
        // @> VULN: factor is 0 and cannot be configured, so adjusted is 0 and 0 >= claimed reverts
        if (adjustedClaimableAmount >= claimedAmount) {
            revert CollateralAlreadyClaimed(adjustedClaimableAmount, claimedAmount);
        }

        uint256 remainingClaimableAmount = adjustedClaimableAmount - claimedAmount;
        dataStore.setUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account), adjustedClaimableAmount);
        require(CollateralToken(token).transfer(receiver, remainingClaimableAmount), "transfer");
        return remainingClaimableAmount;
    }
}

contract MarketBankFixed {
    error CollateralAlreadyClaimed(uint256 adjustedClaimableAmount, uint256 claimedAmount);

    DataStore public immutable dataStore;
    CollateralToken public immutable collateral;

    constructor(DataStore store, CollateralToken token) {
        dataStore = store;
        collateral = token;
    }

    function credit(address account, uint256 timeKey, uint256 amount) external {
        address market = address(this);
        bytes32 amountKey = Keys.claimableCollateralAmountKey(market, address(collateral), timeKey, account);
        uint256 next = dataStore.getUint(amountKey) + amount;
        dataStore.setUint(amountKey, next);
        collateral.mint(market, amount);
    }

    // Control claim. Same reads as the audited function. The comparison is the
    // one later MarketUtils shipped (`<=`), so a non-zero factor can pay.
    function claimCollateral(address market, address token, uint256 timeKey, address account, address receiver)
        external
        returns (uint256)
    {
        require(market == address(this), "market");
        uint256 claimableAmount = dataStore.getUint(Keys.claimableCollateralAmountKey(market, token, timeKey, account));
        uint256 claimableFactor = dataStore.getUint(Keys.claimableCollateralFactorKey(market, token, timeKey, account));
        uint256 claimedAmount = dataStore.getUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account));

        uint256 adjustedClaimableAmount = Precision.applyFactor(claimableAmount, claimableFactor);
        // FIX: `<=` so a factor of 1e30 pays claimableAmount - claimedAmount
        if (adjustedClaimableAmount <= claimedAmount) {
            revert CollateralAlreadyClaimed(adjustedClaimableAmount, claimedAmount);
        }

        uint256 remainingClaimableAmount = adjustedClaimableAmount - claimedAmount;
        dataStore.setUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account), adjustedClaimableAmount);
        require(CollateralToken(token).transfer(receiver, remainingClaimableAmount), "transfer");
        return remainingClaimableAmount;
    }
}

contract Config {
    error InvalidBaseKey(bytes32 baseKey);
    error Unauthorized();
    error InvalidFeeFactor(bytes32 baseKey, uint256 value);

    DataStore public immutable dataStore;
    address public immutable configKeeper;
    mapping(bytes32 => bool) public allowedBaseKeys;

    constructor(DataStore store, address keeper) {
        dataStore = store;
        configKeeper = keeper;
        _initAllowedBaseKeys();
    }

    function invalidKeySelector() external pure returns (bytes4) {
        return InvalidBaseKey.selector;
    }

    // Reduced allow-list. The audited _initAllowedBaseKeys sets many keys and
    // does not set CLAIMABLE_COLLATERAL_FACTOR. The H-10 diff adds that one line.
    function _initAllowedBaseKeys() internal {
        allowedBaseKeys[Keys.MIN_COLLATERAL_FACTOR] = true;
        allowedBaseKeys[Keys.MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER] = true;
        allowedBaseKeys[Keys.MIN_COLLATERAL_USD] = true;
        // FIX: allowedBaseKeys[Keys.CLAIMABLE_COLLATERAL_FACTOR] = true;
        allowedBaseKeys[Keys.VIRTUAL_TOKEN_ID] = true;
        allowedBaseKeys[Keys.VIRTUAL_MARKET_ID] = true;
        allowedBaseKeys[Keys.VIRTUAL_INVENTORY_FOR_SWAPS] = true;
    }

    function setUint(bytes32 baseKey, bytes memory data, uint256 value) external {
        if (msg.sender != configKeeper) revert Unauthorized();
        _validateKey(baseKey);
        _validateRange(baseKey, value);
        bytes32 fullKey = keccak256(bytes.concat(baseKey, data));
        dataStore.setUint(fullKey, value);
    }

    function _validateKey(bytes32 baseKey) internal view {
        bool allowed = allowedBaseKeys[baseKey];
        if (!allowed) {
            revert InvalidBaseKey(baseKey);
        }
    }

    function _validateRange(bytes32 baseKey, uint256 value) internal pure {
        if (baseKey == Keys.POSITION_FEE_FACTOR) {
            revert InvalidFeeFactor(baseKey, value);
        }
    }
}

contract ConfigFixed {
    error InvalidBaseKey(bytes32 baseKey);
    error Unauthorized();
    error InvalidFeeFactor(bytes32 baseKey, uint256 value);

    DataStore public immutable dataStore;
    address public immutable configKeeper;
    mapping(bytes32 => bool) public allowedBaseKeys;

    constructor(DataStore store, address keeper) {
        dataStore = store;
        configKeeper = keeper;
        _initAllowedBaseKeys();
    }

    // H-10 fix: the keeper may set CLAIMABLE_COLLATERAL_FACTOR.
    function _initAllowedBaseKeys() internal {
        allowedBaseKeys[Keys.MIN_COLLATERAL_FACTOR] = true;
        allowedBaseKeys[Keys.MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER] = true;
        allowedBaseKeys[Keys.MIN_COLLATERAL_USD] = true;
        allowedBaseKeys[Keys.CLAIMABLE_COLLATERAL_FACTOR] = true;
        allowedBaseKeys[Keys.VIRTUAL_TOKEN_ID] = true;
        allowedBaseKeys[Keys.VIRTUAL_MARKET_ID] = true;
        allowedBaseKeys[Keys.VIRTUAL_INVENTORY_FOR_SWAPS] = true;
    }

    function setUint(bytes32 baseKey, bytes memory data, uint256 value) external {
        if (msg.sender != configKeeper) revert Unauthorized();
        _validateKey(baseKey);
        _validateRange(baseKey, value);
        bytes32 fullKey = keccak256(bytes.concat(baseKey, data));
        dataStore.setUint(fullKey, value);
    }

    function _validateKey(bytes32 baseKey) internal view {
        bool allowed = allowedBaseKeys[baseKey];
        if (!allowed) {
            revert InvalidBaseKey(baseKey);
        }
    }

    function _validateRange(bytes32 baseKey, uint256 value) internal pure {
        if (baseKey == Keys.POSITION_FEE_FACTOR) {
            revert InvalidFeeFactor(baseKey, value);
        }
    }
}

contract Exploit {
    address public constant TRADER = 0x2222222222222222222222222222222222222222;
    uint256 public constant N = 1000 ether;
    uint256 public constant TIME_KEY = 1;

    CollateralToken public token; // CREATE nonce 1
    DataStore public dataStore; // CREATE nonce 2
    MarketBank public bank; // CREATE nonce 3
    Config public config; // CREATE nonce 4

    uint256 public recorded;
    uint256 public stuck;
    uint256 public traderBal;
    uint256 public factor;
    bytes4 public claimSelector;
    bytes4 public keySelector;
    bool public claimPaid;
    bool public factorSet;

    uint256 public controlPaid;
    uint256 public controlStuck;
    uint256 public controlFactor;

    constructor() {
        token = new CollateralToken();
        dataStore = new DataStore();
        bank = new MarketBank(dataStore, token);
        config = new Config(dataStore, address(this));
    }

    function run() external {
        bank.credit(TRADER, TIME_KEY, N);
        recorded = bank.recorded();

        claimPaid = true;
        try bank.claimCollateral(address(bank), address(token), TIME_KEY, TRADER, TRADER) returns (uint256) {
            claimPaid = true;
        } catch (bytes memory reason) {
            claimPaid = false;
            claimSelector = _sel(reason);
        }

        factorSet = true;
        try config.setUint(
            Keys.CLAIMABLE_COLLATERAL_FACTOR,
            abi.encode(address(bank), address(token), TIME_KEY, TRADER),
            Precision.FLOAT_PRECISION
        ) {
            factorSet = true;
        } catch (bytes memory reason) {
            factorSet = false;
            keySelector = _sel(reason);
        }

        stuck = token.balanceOf(address(bank));
        traderBal = token.balanceOf(TRADER);
        factor = dataStore.getUint(Keys.claimableCollateralFactorKey(address(bank), address(token), TIME_KEY, TRADER));

        require(recorded == N, "recorded");
        require(claimPaid == false, "claim paid");
        require(claimSelector == bank.claimErrorSelector(), "claim selector");
        require(factorSet == false, "factor set");
        require(keySelector == config.invalidKeySelector(), "key selector");
        require(factor == 0, "factor");
        require(stuck == N, "stuck");
        require(traderBal == 0, "trader");
    }

    // Allowing the key is not enough: the audited `>=` still reverts at factor 1e30.
    function runFactorOnly() external {
        bank.credit(TRADER, TIME_KEY, N);
        ConfigFixed opened = new ConfigFixed(dataStore, address(this));
        opened.setUint(
            Keys.CLAIMABLE_COLLATERAL_FACTOR,
            abi.encode(address(bank), address(token), TIME_KEY, TRADER),
            Precision.FLOAT_PRECISION
        );
        factor = dataStore.getUint(Keys.claimableCollateralFactorKey(address(bank), address(token), TIME_KEY, TRADER));
        claimPaid = true;
        try bank.claimCollateral(address(bank), address(token), TIME_KEY, TRADER, TRADER) returns (uint256) {
            claimPaid = true;
        } catch (bytes memory reason) {
            claimPaid = false;
            claimSelector = _sel(reason);
        }
        stuck = token.balanceOf(address(bank));
        traderBal = token.balanceOf(TRADER);
        require(factor == Precision.FLOAT_PRECISION, "factor not stored");
        require(claimPaid == false, "audited comparison paid");
        require(stuck == N, "factor-only stuck");
        require(traderBal == 0, "factor-only trader");
    }

    // Control: allow the key, set the factor to 100%, claim with `<=`, pay N.
    function runControl() external {
        DataStore store = new DataStore();
        MarketBankFixed fixedBank = new MarketBankFixed(store, token);
        ConfigFixed opened = new ConfigFixed(store, address(this));
        fixedBank.credit(TRADER, TIME_KEY, N);
        opened.setUint(
            Keys.CLAIMABLE_COLLATERAL_FACTOR,
            abi.encode(address(fixedBank), address(token), TIME_KEY, TRADER),
            Precision.FLOAT_PRECISION
        );
        controlFactor = store.getUint(
            Keys.claimableCollateralFactorKey(address(fixedBank), address(token), TIME_KEY, TRADER)
        );
        uint256 paid = fixedBank.claimCollateral(address(fixedBank), address(token), TIME_KEY, TRADER, TRADER);
        controlPaid = token.balanceOf(TRADER);
        controlStuck = token.balanceOf(address(fixedBank));
        require(controlFactor == Precision.FLOAT_PRECISION, "control factor");
        require(paid == N, "paid");
        require(controlPaid == N, "control paid");
        require(controlStuck == 0, "control stuck");
    }

    function _sel(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 32))
        }
    }
}
