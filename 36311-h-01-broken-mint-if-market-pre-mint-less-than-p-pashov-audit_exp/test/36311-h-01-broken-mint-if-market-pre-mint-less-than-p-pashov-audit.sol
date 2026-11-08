// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Catalyst IPSeed — mint uses the stored premint instead of the curve's p
    (Pashov Audit Group, April review H-01, AuditVault 36311)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    checkParameters allows premint below the curve's free prefix p, as long
    as getBuyPrice(0, premint) is 0. mint then rejects a still-free buy once
    supply + amount passes the smaller stored premint, because net is 0.
    The comparison below is the report's line (@> VULN). */

interface ICurve {
    function getBuyPrice(uint256 supply, uint256 amount, bytes32 curveParameters) external view returns (uint256);
    function decodeP(bytes32 curveParameters) external pure returns (uint256);
}

contract FreePrefixCurve is ICurve {
    function decodeP(bytes32 curveParameters) public pure returns (uint256) {
        return uint256(curveParameters);
    }

    function getBuyPrice(uint256 supply, uint256 amount, bytes32 curveParameters) external pure returns (uint256) {
        uint256 p = uint256(curveParameters);
        if (supply >= p) return amount * 1 ether;
        if (supply + amount <= p) return 0;
        return (supply + amount - p) * 1 ether;
    }
}

contract IPSeed {
    error TradeSizeOutOfRange();
    error ParameterMismatch();
    error UntrustedCurve();

    uint256 public constant MINIMUM_TRADE_SIZE = 1 ether;

    struct MarketParameters {
        uint256 premint;
        ICurve priceCurve;
        bytes32 curveParameters;
    }

    ICurve public trusted;
    mapping(uint256 => MarketParameters) public marketParams;
    mapping(uint256 => uint256) public totalSupply;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;

    constructor(ICurve _trusted) {
        trusted = _trusted;
    }

    function checkParameters(MarketParameters memory params) public view {
        if (address(params.priceCurve) != address(trusted)) revert UntrustedCurve();
        if (params.priceCurve.getBuyPrice(0, params.premint, params.curveParameters) != 0) {
            revert ParameterMismatch();
        }
    }

    function spawn(uint256 tokenId, uint256 premint, bytes32 curveParameters) external {
        MarketParameters memory params = MarketParameters({
            premint: premint,
            priceCurve: trusted,
            curveParameters: curveParameters
        });
        checkParameters(params);
        marketParams[tokenId] = params;
    }

    function getBuyPrice(uint256 tokenId, uint256 amount) public view returns (uint256 gross, uint256 net) {
        MarketParameters memory params = marketParams[tokenId];
        net = params.priceCurve.getBuyPrice(totalSupply[tokenId], amount, params.curveParameters);
        gross = net;
    }

    function mint(uint256 tokenId, uint256 amount) external payable virtual returns (uint256 gross, uint256 net) {
        MarketParameters memory _marketParams = marketParams[tokenId];
        (gross, net) = getBuyPrice(tokenId, amount);
        require(msg.value >= gross, "underpaid");
        if (
            // @> VULN: stored premint can be below the curve's free p, so a still-free mint reverts
            totalSupply[tokenId] + amount > _marketParams.premint && (amount < MINIMUM_TRADE_SIZE || net == 0)
        ) {
            revert TradeSizeOutOfRange();
        }
        balanceOf[tokenId][msg.sender] += amount;
        totalSupply[tokenId] += amount;
    }
}

contract Exploit {
    uint256 public constant P = 100 ether;
    uint256 public constant STORED_PREMINT = 10 ether;
    uint256 public constant WANT = 50 ether;

    FreePrefixCurve public curve;
    IPSeed public market;
    bool public mintOk;
    uint256 public minted;

    constructor() {
        curve = new FreePrefixCurve();
        market = new IPSeed(curve);
    }

    function run() external {
        bytes32 params = bytes32(P);
        require(curve.getBuyPrice(0, STORED_PREMINT, params) == 0, "stored premint is not free");
        require(curve.getBuyPrice(0, WANT, params) == 0, "wanted amount is not inside p");
        require(STORED_PREMINT < P, "premint is not below p");

        market.spawn(1, STORED_PREMINT, params);
        (bool ok,) = address(market).call(abi.encodeWithSelector(market.mint.selector, uint256(1), WANT));
        mintOk = ok;
        minted = market.balanceOf(1, address(this));

        require(!mintOk, "free mint should revert");
        require(minted == 0, "buyer received tokens");
        require(market.totalSupply(1) == 0, "supply moved");
    }
}
