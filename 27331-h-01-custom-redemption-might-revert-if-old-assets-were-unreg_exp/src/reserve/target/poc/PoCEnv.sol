// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../libraries/Fixed.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IAssetRegistry.sol";
import "../interfaces/IBackingManager.sol";
import "../interfaces/IBasketHandler.sol";
import "../interfaces/IRToken.sol";
import "../interfaces/IStRSR.sol";

/// @dev Minimal REAL ERC20 used only for the opaque collateral tokens (USDC/USDT/DAI).
///      The methodology permits a minimal real ERC20 for tokens the protocol treats
///      as opaque; it is NOT part of the vulnerable logic.
contract MiniERC20 is IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        require(balanceOf[f] >= amt, "bal");
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal REAL collateral plugin (a SOUND, registered ICollateral wrapping a token).
///      Collateral pricing/oracle logic is orthogonal to the index-out-of-bounds bug in
///      BasketHandlerP1.quoteCustomRedemption, so a minimal real collateral is used for the
///      opaque backing tokens. All exchange rates are the trivial peg (1 ref/tok, 1 target/ref).
contract MiniCollateral is ICollateral {
    IERC20Metadata internal immutable _erc20;
    bytes32 internal immutable _targetName;

    constructor(IERC20Metadata erc20_, bytes32 targetName_) {
        _erc20 = erc20_;
        _targetName = targetName_;
    }

    function refresh() external {}
    function claimRewards() external {}

    function price() external pure returns (uint192, uint192) {
        return (1e18, 1e18);
    }

    function lotPrice() external pure returns (uint192, uint192) {
        return (1e18, 1e18);
    }

    function bal(address) external pure returns (uint192) {
        return 0;
    }

    function erc20() external view returns (IERC20Metadata) {
        return _erc20;
    }

    function erc20Decimals() external view returns (uint8) {
        return _erc20.decimals();
    }

    function isCollateral() external pure returns (bool) {
        return true;
    }

    function maxTradeVolume() external pure returns (uint192) {
        return 1e30;
    }

    function lastSave() external pure returns (uint48) {
        return 0;
    }

    function targetName() external view returns (bytes32) {
        return _targetName;
    }

    function status() external pure returns (CollateralStatus) {
        return CollateralStatus.SOUND;
    }

    function refPerTok() external pure returns (uint192) {
        return 1e18;
    }

    function targetPerRef() external pure returns (uint192) {
        return 1e18;
    }
}

/// @dev Minimal REAL BackingManager stand-in. AssetRegistryP1 calls grantRTokenAllowance()
///      on registration; that approval is irrelevant to the redemption-array bug.
contract PoCBackingManager {
    function grantRTokenAllowance(IERC20) external {}

    /// @dev Exact copy of the REAL TradingP1.mulDiv wrapper. BasketHandlerP1.safeMulDivFloor
    ///      delegates its fixed-point math to backingManager.mulDiv (a gas trick), so this
    ///      must exist and use the audited FixLib math.
    function mulDiv(uint192 x, uint192 y, uint192 z, RoundingMode round)
        external
        pure
        returns (uint192)
    {
        return FixLib.mulDiv(x, y, z, round);
    }
}

/// @dev Minimal Main (component registry + access control). Main is pure infrastructure,
///      NOT part of the vulnerable logic. It only wires the REAL AssetRegistryP1 and REAL
///      BasketHandlerP1 together and grants OWNER, exactly as the production Deployer would.
contract PoCMain {
    IAssetRegistry public assetRegistry;
    IBackingManager public backingManager;
    IBasketHandler public basketHandler;
    IERC20 public rsr;
    IRToken public rToken;
    IStRSR public stRSR;

    function setComponents(
        IAssetRegistry ar,
        IBackingManager bm,
        IBasketHandler bh,
        IERC20 rsr_,
        IRToken rt,
        IStRSR st
    ) external {
        assetRegistry = ar;
        backingManager = bm;
        basketHandler = bh;
        rsr = rsr_;
        rToken = rt;
        stRSR = st;
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
    }

    function frozen() external pure returns (bool) {
        return false;
    }

    function tradingPausedOrFrozen() external pure returns (bool) {
        return false;
    }

    function issuancePausedOrFrozen() external pure returns (bool) {
        return false;
    }

    function tradingPaused() external pure returns (bool) {
        return false;
    }

    function issuancePaused() external pure returns (bool) {
        return false;
    }
}
