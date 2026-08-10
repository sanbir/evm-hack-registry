// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Ammplify finding 63170 (H-4):
// "Uncollected fees from user's NFT position are stuck in NFTManager if
//  NFTManager.decomposeAndMint is used".
//
// NFTManager.decomposeAndMint converts a user's Uniswap V3 NFT position into
// Ammplify Maker liquidity. The UniV3Decomposer, while decomposing, COLLECTS the
// position's uncollected fees and — per its residual sweep — sends them to
// `caller`, which the decomposer's nonReentrant modifier sets to msg.sender, i.e.
// the NFTManager. decomposeAndMint then mints the NFT but NEVER forwards those
// swept fees to the user (the RFTPayer interface is not used in this path). The
// fees are therefore stranded in NFTManager (and later swept on to MakerFacet),
// permanently lost to the user.
//
// The verbatim vulnerable `decomposeAndMint` body and the verbatim decomposer
// residual-sweep-to-caller snippet are embedded below (source: embedded-solidity
// from the finding; the Ammplify repo is dead). Doubles are provided ONLY for the
// opaque external boundary: the ERC20 fee tokens, OZ ERC721 `_safeMint`, and the
// UniV3 position `collect()` (modelled inside the Decomposer double). The
// vulnerable contract/function itself is real.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful double for Uniswap's TransferHelper.safeTransfer.
library TransferHelper {
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FAILED");
    }
}

/// @dev Minimal ERC20 double for the position's fee tokens (and the marker token).
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal faithful double for OpenZeppelin ERC721 — provides `_safeMint`
///      and ownership tracking. The receiver callback is irrelevant to this
///      finding and is omitted (plain mint), matching a standard ERC721 double.
contract ERC721 {
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _nftBalances;

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _owners[tokenId];
    }

    function nftBalanceOf(address owner) public view returns (uint256) {
        return _nftBalances[owner];
    }

    function _safeMint(address to, uint256 tokenId) internal {
        require(to != address(0), "ERC721: mint to the zero address");
        require(_owners[tokenId] == address(0), "ERC721: token already minted");
        _nftBalances[to] += 1;
        _owners[tokenId] = to;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// UniV3Decomposer double. On decompose it "collects" the position's uncollected
// fees into itself (mimics UniswapV3 collect()) and then runs the VERBATIM
// residual-sweep-to-`caller` snippet from the finding, sending the fees to
// `caller` (== NFTManager, set by the verbatim nonReentrant modifier).
// ─────────────────────────────────────────────────────────────────────────────
contract Decomposer {
    error ReentrancyAttempt();

    address public caller;
    uint256 internal nextAssetId = 1;

    struct Fees {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
    }

    mapping(uint256 => Fees) public positionFees;

    /// @notice Test setup: the UniV3 position `positionId` has these uncollected fees.
    function setPositionFees(uint256 positionId, address t0, address t1, uint256 a0, uint256 a1) external {
        positionFees[positionId] = Fees(t0, t1, a0, a1);
    }

    function feeTokensOf(uint256 positionId) external view returns (address, address) {
        Fees memory f = positionFees[positionId];
        return (f.token0, f.token1);
    }

    // ── verbatim reentrancy guard from the finding ──
    modifier nonReentrant {
        require(caller == address(0), ReentrancyAttempt());
        caller = msg.sender;
        _;
        caller = msg.sender;
    }

    function decompose(
        uint256 positionId,
        bool isCompounding,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (uint256 newAssetId) {
        Fees memory f = positionFees[positionId];

        // Collect the position's uncollected fees into the decomposer
        // (mimics UniswapV3Pool.collect() paying fees to this contract).
        MiniToken(f.token0).mint(address(this), f.amount0);
        MiniToken(f.token1).mint(address(this), f.amount1);

        _sweepResidual(f.token0);
        _sweepResidual(f.token1);

        newAssetId = nextAssetId++;
    }

    function _sweepResidual(address token) internal {
        // After primary transfer, sweep any dust the contract may still hold for this token
        uint256 residual = IERC20(token).balanceOf(address(this));
        if (residual > 0) {
            TransferHelper.safeTransfer(token, caller, residual); // sends fees to caller == NFTManager
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: NFTManager. `decomposeAndMint` body is verbatim from the
// finding — it decomposes the position (fees are swept into THIS contract) and
// mints the NFT, but never forwards the swept fees to the user.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTManager is ERC721 {
    Decomposer public immutable DECOMPOSER;

    uint256 internal _nextTokenId;
    uint256 internal _currentSupply;
    address internal _currentTokenRequester;
    mapping(uint256 => uint256) public assetToToken;
    mapping(uint256 => uint256) public tokenToAsset;

    event PositionDecomposedAndMinted(
        uint256 indexed positionId, uint256 assetId, uint256 tokenId, address indexed owner
    );

    constructor(address decomposer) {
        DECOMPOSER = Decomposer(decomposer);
    }

    function decomposeAndMint(
        uint256 positionId,
        bool isCompounding,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 assetId, uint256 tokenId) {
        _currentTokenRequester = msg.sender;

        // Decompose the Uniswap V3 position
        assetId = DECOMPOSER.decompose(positionId, isCompounding, minSqrtPriceX96, maxSqrtPriceX96, rftData);

        // Clear the token requester context
        _currentTokenRequester = address(0); // @> swept uncollected fees now sit in NFTManager; decomposeAndMint never forwards them to msg.sender (no residual transfer, RFTPayer unused)

        // Mint NFT for the decomposed asset
        tokenId = _nextTokenId++;
        assetToToken[assetId] = tokenId;
        tokenToAsset[tokenId] = assetId;
        _currentSupply++;

        _safeMint(msg.sender, tokenId);

        emit PositionDecomposedAndMinted(positionId, assetId, tokenId, msg.sender);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): after minting, forward the residual fees
// swept into the manager back to the user (per the finding's mitigation).
// ─────────────────────────────────────────────────────────────────────────────
contract NFTManagerFixed is ERC721 {
    Decomposer public immutable DECOMPOSER;

    uint256 internal _nextTokenId;
    uint256 internal _currentSupply;
    address internal _currentTokenRequester;
    mapping(uint256 => uint256) public assetToToken;
    mapping(uint256 => uint256) public tokenToAsset;

    event PositionDecomposedAndMinted(
        uint256 indexed positionId, uint256 assetId, uint256 tokenId, address indexed owner
    );

    constructor(address decomposer) {
        DECOMPOSER = Decomposer(decomposer);
    }

    function decomposeAndMint(
        uint256 positionId,
        bool isCompounding,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 assetId, uint256 tokenId) {
        _currentTokenRequester = msg.sender;

        assetId = DECOMPOSER.decompose(positionId, isCompounding, minSqrtPriceX96, maxSqrtPriceX96, rftData);

        _currentTokenRequester = address(0);

        tokenId = _nextTokenId++;
        assetToToken[assetId] = tokenId;
        tokenToAsset[tokenId] = assetId;
        _currentSupply++;

        _safeMint(msg.sender, tokenId);

        // FIX: forward the residual uncollected fees swept into this contract to the user.
        (address t0, address t1) = DECOMPOSER.feeTokensOf(positionId);
        _forwardResidual(t0, msg.sender);
        _forwardResidual(t1, msg.sender);

        emit PositionDecomposedAndMinted(positionId, assetId, tokenId, msg.sender);
    }

    function _forwardResidual(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            TransferHelper.safeTransfer(token, to, bal);
        }
    }
}

/// @dev The position owner. Calls decomposeAndMint so msg.sender (the user) is a
///      distinct address whose fee balance we can inspect.
contract User {
    function doDecompose(NFTManager nft, uint256 positionId) external {
        nft.decomposeAndMint(positionId, false, 0, 0, "");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a user with 100 + 100 uncollected fees calls decomposeAndMint.
// The fees are swept into NFTManager and never reach the user — a permanent loss.
// The magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant POSITION_ID = 42;
    uint256 internal constant FEE0 = 100 ether;
    uint256 internal constant FEE1 = 100 ether;

    address public token0Addr;
    address public token1Addr;
    address public nftManagerAddr;
    address public userAddr;
    address public markerAddr;

    uint256 public userFee0After;
    uint256 public userFee1After;
    uint256 public stuckFee0;
    uint256 public stuckFee1;
    uint256 public strandedFees;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        MiniToken token0 = new MiniToken("Fee Token 0", "FEE0");             // nonce 1
        MiniToken token1 = new MiniToken("Fee Token 1", "FEE1");             // nonce 2
        Decomposer decomposer = new Decomposer();                            // nonce 3
        NFTManager nft = new NFTManager(address(decomposer));                // nonce 4
        User user = new User();                                              // nonce 5
        MiniToken marker = new MiniToken("Locked User Fees", "LOCKED-FEES"); // nonce 6 (LAST)

        token0Addr = address(token0);
        token1Addr = address(token1);
        nftManagerAddr = address(nft);
        userAddr = address(user);
        markerAddr = address(marker);

        // The user's UniV3 position carries 100 + 100 uncollected fees.
        decomposer.setPositionFees(POSITION_ID, address(token0), address(token1), FEE0, FEE1);

        // User decomposes their position into Maker liquidity and mints the NFT.
        user.doDecompose(nft, POSITION_ID);

        // Harm: the user received NONE of their uncollected fees...
        userFee0After = token0.balanceOf(address(user));
        userFee1After = token1.balanceOf(address(user));
        // ...the fees are stuck in NFTManager instead.
        stuckFee0 = token0.balanceOf(address(nft));
        stuckFee1 = token1.balanceOf(address(nft));

        require(userFee0After == 0 && userFee1After == 0, "user unexpectedly received fees");
        require(stuckFee0 == FEE0 && stuckFee1 == FEE1, "fees not stuck in NFTManager");

        // Record the magnitude of the permanent user loss on a marker at the SINK.
        strandedFees = stuckFee0 + stuckFee1;
        marker.mint(SINK, strandedFees);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
