// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/// @dev Minimal real WETH9 (deposit/withdraw/ERC20). Opaque wrapped-ETH token the
/// protocol treats as a plain asset; its internals are NOT part of any audited bug.
contract WETH9Double {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WETH: insufficient");
        balanceOf[msg.sender] -= wad;
        (bool ok, ) = payable(msg.sender).call{value: wad}("");
        require(ok, "WETH: ETH send failed");
    }

    function totalSupply() external view returns (uint256) { return address(this).balance; }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        return true;
    }

    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WETH: balance");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "WETH: allowance");
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        return true;
    }
}

/// @dev Minimal real Ionic cToken (Compound-fork) double. The protocol deposits
/// WETH collateral here and redeems it 1:1; the lending yield is irrelevant to the
/// three audited accounting bugs, so a fixed 1e18 exchange rate is faithful.
interface IWETHLike {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract IonicDouble {
    IWETHLike public immutable weth;
    mapping(address => uint256) public balanceOf; // cToken balance (1:1 with underlying)

    constructor(address weth_) {
        weth = IWETHLike(weth_);
    }

    function exchangeRateCurrent() external pure returns (uint256) {
        return 1e18;
    }

    // Pulls `mintAmount` WETH from caller, credits cTokens 1:1.
    function mint(uint256 mintAmount) external payable {
        require(weth.transferFrom(msg.sender, address(this), mintAmount), "ionic: pull failed");
        balanceOf[msg.sender] += mintAmount;
    }

    // Returns `redeemAmount` WETH to caller, burns the cTokens 1:1.
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        require(balanceOf[msg.sender] >= redeemAmount, "ionic: balance");
        balanceOf[msg.sender] -= redeemAmount;
        require(weth.transfer(msg.sender, redeemAmount), "ionic: push failed");
        return 0;
    }

    function balanceOfUnderlying(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function transfer(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint256) { return 0; }
}

/// @dev Synthetix short-hedge doubles for liquidationType2. These are truly-external
/// derivatives venues; their internals are irrelevant to the missing-state-write bug.
contract SynthetixWrapperDouble {
    uint256 public minted;
    function mint(uint256 amount) external { minted += amount; }
}

contract SynthetixExchangeDouble {
    uint256 public exchanged;
    function exchange(bytes32, uint256 sourceAmount, bytes32) external returns (uint256) {
        exchanged += sourceAmount;
        return sourceAmount;
    }
}

contract PerpsV2Double {
    int256 public margin;
    int256 public lastOrderSize;
    uint256 public lastOrderPrice;

    function transferMargin(int256 marginDelta) external { margin += marginDelta; }

    function submitOffchainDelayedOrder(int256 sizeDelta, uint256 desiredFillPrice) external {
        lastOrderSize = sizeDelta;
        lastOrderPrice = desiredFillPrice;
    }
}

/// @dev Controllable RedStone-style price oracle double (18-decimal USD prices),
/// matching the IRedstoneOracle interface MasterPriceOracle uses on non-forked
/// chains. Prices are settable so tests can move ETH up/down. This is the same
/// class of price feed the audited MasterPriceOracle already consumes; only the
/// data source is local instead of a live RedStone feed.
contract RedstoneOracleDouble {
    // RedStone-mapped asset addresses used inside MasterPriceOracle on chainid 31337
    address internal constant WEETH_RS = 0x028227c4dd1e5419d11Bb6fa6e661920c519D4F5;
    address internal constant WRSETH_RS = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;

    uint256 public ethPrice18; // ETH/USD, 18 decimals
    uint256 public weethPrice18;
    uint256 public wrsethPrice18;

    constructor() {
        ethPrice18 = 1000e18;
        weethPrice18 = 1100e18;
        wrsethPrice18 = 1100e18;
    }

    function setEthPrice18(uint256 p) external { ethPrice18 = p; }
    function setWeethPrice18(uint256 p) external { weethPrice18 = p; }
    function setWrsethPrice18(uint256 p) external { wrsethPrice18 = p; }

    function priceOf(address asset) external view returns (uint256) {
        if (asset == address(0)) return ethPrice18;
        if (asset == WEETH_RS) return weethPrice18;
        if (asset == WRSETH_RS) return wrsethPrice18;
        return ethPrice18;
    }

    function priceOfETH() external view returns (uint256) {
        return ethPrice18;
    }

    function getDataFeedIdForAsset(address) external pure returns (bytes32) { return bytes32(0); }
    function getDataFeedIds() external pure returns (bytes32[] memory ids) { ids = new bytes32[](0); }
}
