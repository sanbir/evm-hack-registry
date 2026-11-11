// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Particle — getOwedFee returns 0 when Uniswap fee growth has wrapped
    (Cantina Feb 2024, finding 40714).
    SYNTHETIC, cheatcode-free. The `>` comparison is the audited line (@> VULN).
    Root cause: feeGrowthInside is allowed to underflow, the way Uniswap V3
    does on Solidity <0.8. A strict greater-than treats a wrapped growth value
    as "no new fees", so a position that owes 3e18 pays 0. */

library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return a * b / denominator;
    }
}

library FixedPoint128 {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FeeVault {
    MockToken public token;
    address public lp;
    bool public corrected;
    uint256 public feeGrowthInside0X128;
    uint256 public feeGrowthInside0LastX128;
    uint128 public liquidity;
    uint128 public paid;

    constructor(address _token, address _lp, bool _corrected) {
        token = MockToken(_token);
        lp = _lp;
        corrected = _corrected;
        feeGrowthInside0LastX128 = type(uint256).max - 1e18 + 1;
        feeGrowthInside0X128 = 2e18;
        liquidity = type(uint128).max;
    }

    /// Audited body. The comparison is the bug. Uniswap subtracts unchecked.
    function getOwedFee(
        uint256 _feeGrowthInside0X128,
        uint256 _feeGrowthInside1X128,
        uint256 _feeGrowthInside0LastX128,
        uint256 _feeGrowthInside1LastX128,
        uint128 _liquidity
    ) public pure returns (uint128 token0Owed, uint128 token1Owed) {
        // @> VULN: wrapped growth is not greater than last, so the owed fee stays 0.
        if (_feeGrowthInside0X128 > _feeGrowthInside0LastX128) {
            token0Owed = uint128(
                FullMath.mulDiv(_feeGrowthInside0X128 - _feeGrowthInside0LastX128, _liquidity, FixedPoint128.Q128)
            );
        }
        if (_feeGrowthInside1X128 > _feeGrowthInside1LastX128) {
            token1Owed = uint128(
                FullMath.mulDiv(_feeGrowthInside1X128 - _feeGrowthInside1LastX128, _liquidity, FixedPoint128.Q128)
            );
        }
    }

    /// The report's fix: subtract in unchecked math, and skip only when equal.
    function getOwedFeeFixed(
        uint256 _feeGrowthInside0X128,
        uint256 _feeGrowthInside0LastX128,
        uint128 _liquidity
    ) public pure returns (uint128 token0Owed) {
        unchecked {
            if (_feeGrowthInside0X128 != _feeGrowthInside0LastX128) {
                token0Owed = uint128(
                    FullMath.mulDiv(_feeGrowthInside0X128 - _feeGrowthInside0LastX128, _liquidity, FixedPoint128.Q128)
                );
            }
        }
    }

    function close() external returns (uint128 token0Owed) {
        if (corrected) {
            token0Owed = getOwedFeeFixed(feeGrowthInside0X128, feeGrowthInside0LastX128, liquidity);
        } else {
            (token0Owed,) = getOwedFee(feeGrowthInside0X128, 0, feeGrowthInside0LastX128, 0, liquidity);
        }
        paid = token0Owed;
        if (token0Owed > 0) {
            token.transfer(lp, token0Owed);
        }
    }
}

contract Lp {}

contract Stack {
    MockToken public token;
    Lp public lp;
    FeeVault public vault;

    constructor(bool corrected) {
        token = new MockToken("Token0", "TK0");
        lp = new Lp();
        vault = new FeeVault(address(token), address(lp), corrected);
    }

    function go() external {
        token.mint(address(vault), 3e18 - 1);
        vault.close();
    }
}

contract Exploit {
    Stack public stack;
    uint128 public fair;

    constructor() {
        stack = new Stack(false);
    }

    function run() external {
        stack.go();
        FeeVault vault = stack.vault();
        fair = vault.getOwedFeeFixed(vault.feeGrowthInside0X128(), vault.feeGrowthInside0LastX128(), vault.liquidity());
        require(vault.paid() == 0, "paid");
        require(fair == 3e18 - 1, "fair");
        require(stack.token().balanceOf(address(stack.lp())) == 0, "lp");
        require(stack.token().balanceOf(address(vault)) == 3e18 - 1, "kept");
    }
}
