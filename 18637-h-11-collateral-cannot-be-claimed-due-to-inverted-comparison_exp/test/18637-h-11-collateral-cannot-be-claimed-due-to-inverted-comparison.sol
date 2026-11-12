// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*
 * GMX Synthetics — MarketUtils.claimCollateral (Sherlock 2023-02-gmx H-11, AuditVault 18637)
 *
 * SYNTHETIC, cheatcode-free reduction. The blamed comparison is the audited
 * condition, copied verbatim. claimedAmount starts at 0, so
 * `adjustedClaimableAmount >= claimedAmount` is true for every positive credit
 * and the claim reverts. The 1000 collateral tokens stay in the market.
 *
 * The control contract uses `<=` (the shipped fix) and pays those 1000 tokens
 * to the trader.
 *
 * Vulnerable source:
 * https://github.com/sherlock-audit/2023-02-gmx/blob/main/gmx-synthetics/contracts/market/MarketUtils.sol#L622-L644
 */

error CollateralAlreadyClaimed(uint256 adjustedClaimableAmount, uint256 claimedAmount);

contract CollateralToken {
    string public constant name = "Collateral";
    string public constant symbol = "COLL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "COLL: balance");
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

library Keys {
    function claimableCollateralAmountKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("CLAIMABLE_COLLATERAL_AMOUNT", market, token, timeKey, account));
    }

    function claimableCollateralFactorKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("CLAIMABLE_COLLATERAL_FACTOR", market, token, timeKey, account));
    }

    function claimedCollateralAmountKey(address market, address token, uint256 timeKey, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("CLAIMED_COLLATERAL_AMOUNT", market, token, timeKey, account));
    }
}

library Precision {
    uint256 internal constant FLOAT_PRECISION = 10 ** 30;

    function applyFactor(uint256 value, uint256 factor) internal pure returns (uint256) {
        return (value * factor) / FLOAT_PRECISION;
    }
}

contract MarketUtils {
    DataStore public dataStore;
    CollateralToken public collateral;
    uint256 public escrowed;

    constructor(DataStore store_, CollateralToken token_) {
        dataStore = store_;
        collateral = token_;
    }

    function floatPrecision() external pure returns (uint256) {
        return Precision.FLOAT_PRECISION;
    }

    function creditClaimable(
        address market,
        address token,
        uint256 timeKey,
        address account,
        uint256 amount,
        uint256 factor
    ) external returns (uint256) {
        require(token == address(collateral), "token");
        collateral.mint(address(this), amount);
        escrowed = collateral.balanceOf(address(this));
        bytes32 amountKey = Keys.claimableCollateralAmountKey(market, token, timeKey, account);
        dataStore.setUint(amountKey, amount);
        bytes32 factorKey = Keys.claimableCollateralFactorKey(market, token, timeKey, account);
        dataStore.setUint(factorKey, factor);
        return escrowed;
    }

    function previewAdjusted(address market, address token, uint256 timeKey, address account)
        external
        view
        returns (uint256)
    {
        uint256 claimableAmount = dataStore.getUint(Keys.claimableCollateralAmountKey(market, token, timeKey, account));
        uint256 claimableFactor = dataStore.getUint(Keys.claimableCollateralFactorKey(market, token, timeKey, account));
        return Precision.applyFactor(claimableAmount, claimableFactor);
    }

    function previewClaimed(address market, address token, uint256 timeKey, address account)
        external
        view
        returns (uint256)
    {
        return dataStore.getUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account));
    }

    // Audited MarketUtils.claimCollateral. The comparison below is the blamed line.
    function claimCollateral(address market, address token, uint256 timeKey, address account, address receiver)
        external
        virtual
    {
        require(token == address(collateral), "token");
        uint256 claimableAmount = dataStore.getUint(Keys.claimableCollateralAmountKey(market, token, timeKey, account));
        uint256 claimableFactor = dataStore.getUint(Keys.claimableCollateralFactorKey(market, token, timeKey, account));
        uint256 claimedAmount = dataStore.getUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account));

        uint256 adjustedClaimableAmount = Precision.applyFactor(claimableAmount, claimableFactor);
        // @> VULN: inverted comparison. claimedAmount starts at 0, so any positive adjusted amount reverts and the collateral can never be paid out.
        if (adjustedClaimableAmount >= claimedAmount) {
            revert CollateralAlreadyClaimed(adjustedClaimableAmount, claimedAmount);
        }

        uint256 remainingClaimableAmount = adjustedClaimableAmount - claimedAmount;
        dataStore.setUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account), adjustedClaimableAmount);
        collateral.transfer(receiver, remainingClaimableAmount);
    }
}

/// Fix from gmx-synthetics PR 70: revert only when nothing remains to claim.
contract MarketUtilsFixed is MarketUtils {
    constructor(DataStore store_, CollateralToken token_) MarketUtils(store_, token_) {}

    function claimCollateral(address market, address token, uint256 timeKey, address account, address receiver)
        external
        override
    {
        require(token == address(collateral), "token");
        uint256 claimableAmount = dataStore.getUint(Keys.claimableCollateralAmountKey(market, token, timeKey, account));
        uint256 claimableFactor = dataStore.getUint(Keys.claimableCollateralFactorKey(market, token, timeKey, account));
        uint256 claimedAmount = dataStore.getUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account));

        uint256 adjustedClaimableAmount = Precision.applyFactor(claimableAmount, claimableFactor);
        // FIX: `<=` — pay the positive remainder, revert only once it is exhausted.
        if (adjustedClaimableAmount <= claimedAmount) {
            revert CollateralAlreadyClaimed(adjustedClaimableAmount, claimedAmount);
        }

        uint256 remainingClaimableAmount = adjustedClaimableAmount - claimedAmount;
        dataStore.setUint(Keys.claimedCollateralAmountKey(market, token, timeKey, account), adjustedClaimableAmount);
        collateral.transfer(receiver, remainingClaimableAmount);
    }
}

contract Exploit {
    address public constant USER = 0x2222222222222222222222222222222222222222;
    uint256 public constant COLLATERAL = 1000 ether;
    uint256 public constant TIME_KEY = 1;

    CollateralToken public token; // nonce 1
    DataStore public store; // nonce 2
    MarketUtils public market; // nonce 3

    uint256 public factorUsed;
    uint256 public credited;
    uint256 public adjustedBefore;
    uint256 public claimedBefore;
    bool public claimReverted;
    bytes4 public revertSelector;
    uint256 public stuck;
    uint256 public userReceived;

    uint256 public controlPaid;
    uint256 public controlLeft;
    bool public controlSecondReverted;

    constructor() {
        token = new CollateralToken();
        store = new DataStore();
        market = new MarketUtils(store, token);
    }

    function expectedSelector() external pure returns (bytes4) {
        return CollateralAlreadyClaimed.selector;
    }

    function run() external {
        factorUsed = market.floatPrecision();
        credited = market.creditClaimable(address(market), address(token), TIME_KEY, USER, COLLATERAL, factorUsed);
        adjustedBefore = market.previewAdjusted(address(market), address(token), TIME_KEY, USER);
        claimedBefore = market.previewClaimed(address(market), address(token), TIME_KEY, USER);
        (bool ok, bytes memory err) = address(market).call(
            abi.encodeWithSelector(
                market.claimCollateral.selector, address(market), address(token), TIME_KEY, USER, USER
            )
        );
        claimReverted = !ok;
        if (err.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            revertSelector = sel;
        }
        stuck = token.balanceOf(address(market));
        userReceived = token.balanceOf(USER);
        require(factorUsed == 10 ** 30, "factor");
        require(credited == COLLATERAL, "credit");
        require(adjustedBefore == COLLATERAL, "adjusted");
        require(claimedBefore == 0, "claimed starts at zero");
        require(claimReverted, "claim did not revert");
        require(revertSelector == CollateralAlreadyClaimed.selector, "selector");
        require(stuck == COLLATERAL, "collateral not stuck");
        require(userReceived == 0, "user was paid");
    }

    function runControl() external {
        MarketUtilsFixed fixedMarket = new MarketUtilsFixed(store, token);
        uint256 factor = fixedMarket.floatPrecision();
        uint256 booked = fixedMarket.creditClaimable(address(fixedMarket), address(token), TIME_KEY, USER, COLLATERAL, factor);
        fixedMarket.claimCollateral(address(fixedMarket), address(token), TIME_KEY, USER, USER);
        controlPaid = token.balanceOf(USER);
        controlLeft = token.balanceOf(address(fixedMarket));
        (bool secondOk,) = address(fixedMarket).call(
            abi.encodeWithSelector(
                fixedMarket.claimCollateral.selector, address(fixedMarket), address(token), TIME_KEY, USER, USER
            )
        );
        controlSecondReverted = !secondOk;
        require(booked == COLLATERAL, "control credit");
        require(controlPaid == COLLATERAL, "control did not pay user");
        require(controlLeft == 0, "control left collateral stuck");
        require(controlSecondReverted, "second claim should revert");
    }
}
