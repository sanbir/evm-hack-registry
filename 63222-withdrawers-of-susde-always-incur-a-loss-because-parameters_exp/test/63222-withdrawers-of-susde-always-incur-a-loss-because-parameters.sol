// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Strata Tranches — withdrawers of sUSDe always incur a loss because
    parameters passed from Tranche::_withdraw to CDO::withdraw are inverted
    (Cyfrin 2025-10-08, finding #63222)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Tranche passes (baseAssets, tokenAssets) but CDO/Strategy
    expect (tokenAmount, baseAssets). Strategy then does
    sUSDe.previewWithdraw(baseAssets) with the WRONG value (tokenAssets),
    releasing ~66 sUSDe for a 100 sUSDe request at 1.5 exchange rate while
    burning full Tranche shares. Blamed call site preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Minimal sUSDe: ERC4626-style shares of USDe. convertToAssets = assets/supply.
contract MockSUSDe is MockERC20 {
    MockERC20 public immutable asset;

    constructor(MockERC20 usde) MockERC20("Staked USDe", "sUSDe") {
        asset = usde;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 bal = asset.balanceOf(address(this));
        shares = supply == 0 ? assets : (assets * supply) / bal;
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * asset.balanceOf(address(this))) / supply;
    }

    /// @notice Shares needed to withdraw `assets` of USDe (ERC4626 previewWithdraw).
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 bal = asset.balanceOf(address(this));
        if (supply == 0 || bal == 0) return assets;
        // ceil div for fidelity with ERC4626-style previewWithdraw
        return (assets * supply + bal - 1) / bal;
    }
}

/// @dev Holds sUSDe and releases via "cooldown" transfer (instant in synthetic).
contract Strategy {
    MockSUSDe public immutable sUSDe;
    address public cdo;
    address public tranche;

    constructor(MockSUSDe s) {
        sUSDe = s;
    }

    function setCdo(address c) external {
        cdo = c;
    }

    function setTranche(address t) external {
        tranche = t;
    }

    function pull(uint256 amount) external {
        require(msg.sender == tranche || msg.sender == cdo, "onlyTranche");
        sUSDe.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Source: Strategy::withdraw — baseAssets should be USDe value.
    function withdraw(address /*tranche_*/, address token, uint256 /*tokenAmount*/, uint256 baseAssets, address receiver)
        external
        returns (uint256)
    {
        require(msg.sender == cdo, "onlyCDO");
        // @audit => `baseAssets` should be USDe being withdrawn; when inverted it is sUSDe amount
        uint256 shares = sUSDe.previewWithdraw(baseAssets);
        if (token == address(sUSDe)) {
            sUSDe.transfer(receiver, shares);
            return shares;
        }
        revert("token");
    }
}

contract StrataCDO {
    Strategy public immutable strategy;
    address public tranche;

    constructor(Strategy s) {
        strategy = s;
    }

    function setTranche(address t) external {
        tranche = t;
    }

    /// @notice Source: StrataCDO::withdraw — expects (tokenAmount, baseAssets).
    function withdraw(address tranche_, address token, uint256 tokenAmount, uint256 baseAssets, address receiver)
        external
    {
        require(msg.sender == tranche, "onlyTranche");
        // Because of inverted params, tokenAmount is actually baseAssets and baseAssets is tokenAssets
        strategy.withdraw(tranche_, token, tokenAmount, baseAssets, receiver);
    }
}

/// @dev Junior tranche: 1 share == 1 USDe of value at deposit/withdraw.
contract Tranche {
    string public constant name = "JRT";
    string public constant symbol = "JRT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    StrataCDO public immutable cdo;
    MockSUSDe public immutable sUSDe;
    Strategy public immutable strategy;

    constructor(StrataCDO c, MockSUSDe s, Strategy st) {
        cdo = c;
        sUSDe = s;
        strategy = st;
    }

    function deposit(address token, uint256 tokenAmount, address receiver) external returns (uint256 shares) {
        require(token == address(sUSDe), "token");
        uint256 baseAssets = sUSDe.convertToAssets(tokenAmount);
        shares = baseAssets; // 1 share per 1 USDe value
        sUSDe.transferFrom(msg.sender, address(this), tokenAmount);
        sUSDe.approve(address(strategy), tokenAmount);
        strategy.pull(tokenAmount);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(address token, uint256 tokenAssets, address receiver, address owner)
        external
        returns (uint256)
    {
        require(token == address(sUSDe), "token");
        uint256 baseAssets = sUSDe.convertToAssets(tokenAssets);
        uint256 shares = baseAssets;
        require(balanceOf[owner] >= shares, "shares");
        _withdraw(token, msg.sender, receiver, owner, baseAssets, tokenAssets, shares);
        return tokenAssets;
    }

    /// @notice Source: Tranche::_withdraw — inverted arg order to cdo.withdraw.
    function _withdraw(
        address token,
        address /*caller*/,
        address receiver,
        address owner,
        uint256 baseAssets,
        uint256 tokenAssets,
        uint256 shares
    ) internal {
        // Burn Trancheshares for the full requested sUSDe value
        totalSupply -= shares;
        balanceOf[owner] -= shares;

        // Sends baseAssets first and then tokenAssets — inverted vs CDO signature
        cdo.withdraw(address(this), token, baseAssets, tokenAssets, receiver); // @> VULN: inverted (baseAssets, tokenAssets); CDO expects (tokenAmount, baseAssets)
        // FIX: cdo.withdraw(address(this), token, tokenAssets, baseAssets, receiver);
    }
}

/// CREATE order: usde(1), sUSDe(2), strategy(3), cdo(4), tranche(5)
contract Exploit {
    MockERC20 public usde;
    MockSUSDe public sUSDe;
    Strategy public strategy;
    StrataCDO public cdo;
    Tranche public tranche;

    uint256 public expectedSUSDe;
    uint256 public actualSUSDe;
    uint256 public sharesBurned;

    constructor() {
        usde = new MockERC20("USDe", "USDe");
        sUSDe = new MockSUSDe(usde);
        strategy = new Strategy(sUSDe);
        cdo = new StrataCDO(strategy);
        strategy.setCdo(address(cdo));
        tranche = new Tranche(cdo, sUSDe, strategy);
        cdo.setTranche(address(tranche));
        strategy.setTranche(address(tranche));
    }

    function run() external {
        // Bootstrap sUSDe rate to 1:1 then inflate to 1:1.5 (50% yield)
        usde.mint(address(this), 1000 ether);
        usde.approve(address(sUSDe), type(uint256).max);
        sUSDe.deposit(1000 ether, address(this));
        usde.mint(address(sUSDe), 500 ether); // rate → 1.5

        // Alice: 150 USDe → 100 sUSDe → deposit into tranche → 150 JRT shares
        usde.mint(address(this), 150 ether);
        sUSDe.deposit(150 ether, address(this));
        uint256 susdeAmt = sUSDe.balanceOf(address(this));
        // After bootstrap deposit remaining is the new 100 sUSDe (+ leftover from bootstrap)
        // Use exactly 100e18 sUSDe for deposit
        require(susdeAmt >= 100 ether, "need sUSDe");
        // Transfer bootstrap leftovers away so we deposit clean 100e18
        uint256 extra = susdeAmt - 100 ether;
        if (extra > 0) sUSDe.transfer(address(0xB0B), extra);

        sUSDe.approve(address(tranche), type(uint256).max);
        tranche.deposit(address(sUSDe), 100 ether, address(this));
        require(tranche.balanceOf(address(this)) == 150 ether, "jrt shares");

        expectedSUSDe = 100 ether;
        uint256 expectedUSDeValue = sUSDe.convertToAssets(expectedSUSDe);
        require(expectedUSDeValue == 150 ether, "rate");

        // Fund strategy with enough sUSDe for the (buggy) payout path
        // Strategy already holds the deposited 100 sUSDe from pull()

        uint256 before = sUSDe.balanceOf(address(this));
        tranche.withdraw(address(sUSDe), expectedSUSDe, address(this), address(this));
        actualSUSDe = sUSDe.balanceOf(address(this)) - before;
        sharesBurned = 150 ether - tranche.balanceOf(address(this));

        // Harm: full 150 JRT burned, but only ~66.67 sUSDe received (not 100)
        require(tranche.balanceOf(address(this)) == 0, "all shares burned");
        require(sharesBurned == 150 ether, "burned 150");
        require(actualSUSDe < expectedSUSDe, "should receive less sUSDe");
        // ≈ 100e18 * 1500/1000 wait: previewWithdraw(100e18 USDe) at rate 1.5
        // supply and bal after deposits: complex — just assert ~66e18 range
        require(actualSUSDe < 70 ether && actualSUSDe > 60 ether, "~66.67 sUSDe");
        require(sUSDe.convertToAssets(actualSUSDe) < expectedUSDeValue, "USDe value loss");
    }
}
