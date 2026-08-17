// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58151 (C-02):
// "CLGauge sends KITTEN rewards to itself instead of to stakers".
//
// Real audited source (the vulnerable `_getReward` is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   protocol KittenSwap  (Pashov Audit Group, 2025-05-07)
//   report   github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-05-07.md
//   contract CLGauge
//   fn       _getReward(uint256 nfpTokenId)
//
// Root cause: when a user stakes an NFP, ownership of the NFT is transferred to
// the CLGauge contract. On claim, `_getReward` derives the reward recipient from
// `nfp.ownerOf(nfpTokenId)` (the @> line) — which after staking is the gauge
// itself — and then `_safeTransferFrom(kitten, address(this), owner, reward)`
// performs a gauge->gauge self-transfer. The original staker receives nothing;
// 100% of the KITTEN rewards are stranded in the gauge and are unrecoverable.
//
// `_getReward` is byte-for-byte the audited source. Non-vulnerable dependencies
// (KITTEN ERC20, the NFP position manager, `_updateRewardForNfp`, `_safeApprove`,
// `_safeTransferFrom`) are faithful minimal doubles with real transfers/accounting.
// ─────────────────────────────────────────────────────────────────────────────

address constant SINK = 0x000000000000000000000000000000000000D00d;

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface INFP {
    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Faithful minimal KITTEN reward token (bool-returning ERC20, real accounting).
contract MockKitten is IERC20 {
    string public name = "Kitten";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }
}

/// @dev Faithful minimal UniV3-style NFP position manager. `positions` returns
///      the 12-field tuple the gauge destructures; `transferFrom` moves NFT
///      ownership on stake (the reason `ownerOf` later resolves to the gauge).
contract MockNFP is INFP {
    mapping(uint256 => address) private _owner;

    function mint(address to, uint256 tokenId) external {
        _owner[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owner[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owner[tokenId] == from, "not owner");
        _owner[tokenId] = to;
    }

    function positions(uint256) external pure returns (
        uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128
    ) {
        return (0, address(0), address(0), address(0), uint24(0), int24(-120), int24(120), uint128(0), 0, 0, uint128(0), uint128(0));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_getReward` is reproduced VERBATIM from CLGauge.
// ─────────────────────────────────────────────────────────────────────────────
contract CLGauge {
    address public kitten;
    INFP public nfp;

    mapping(uint256 => uint256) public rewards; // accrued KITTEN per staked NFP
    mapping(uint256 => address) public staker;  // real depositor (ignored by the buggy claim)

    event ClaimRewards(address indexed from, uint256 amount);

    constructor(address kitten_, INFP nfp_) {
        kitten = kitten_;
        nfp = nfp_;
    }

    /// @notice Faithful stake path: NFP ownership moves to the gauge.
    function stake(uint256 nfpTokenId) external {
        nfp.transferFrom(msg.sender, address(this), nfpTokenId);
        staker[nfpTokenId] = msg.sender;
    }

    /// @notice Faithful reward-accrual double (records accrued KITTEN amount).
    function notifyReward(uint256 nfpTokenId, uint256 amount) external {
        rewards[nfpTokenId] = amount;
    }

    /// @notice Public claim entrypoint, forwards to the verbatim internal fn.
    function getReward(uint256 nfpTokenId) external {
        _getReward(nfpTokenId);
    }

    // ── faithful minimal double: per-NFP reward accrual (pre-accrued -> no-op) ──
    function _updateRewardForNfp(uint256, int24, int24) internal {}

    // ── faithful Solidly-style safe token helpers (non-vulnerable) ──
    function _safeApprove(address token, address spender, uint256 value) internal {
        require(token.code.length > 0, "!contract");
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0, "!contract");
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    // ─── VERBATIM audited `_getReward` ───
    function _getReward(uint256 nfpTokenId) internal {
        (, , , , , int24 _tickLower, int24 _tickUpper, , , , , ) = nfp
            .positions(nfpTokenId);

        _updateRewardForNfp(nfpTokenId, _tickLower, _tickUpper);

        uint256 reward = rewards[nfpTokenId];
        address owner = nfp.ownerOf(nfpTokenId); // @> VULN: recipient derived from NFP ownership — after stake this is the CLGauge itself, so the reward is self-transferred and lost to the staker

        if (reward > 0) {
            delete rewards[nfpTokenId];
            _safeApprove(kitten, address(this), reward);
            _safeTransferFrom(kitten, address(this), owner, reward);
            emit ClaimRewards(owner, reward);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an honest staker stakes an NFP, KITTEN rewards accrue, and on
// claim the staker receives NOTHING while the full reward is stranded in the
// gauge (self-transfer). The lost magnitude is marked to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockKitten public kitten;
    MockNFP public nfp;
    CLGauge public gauge;

    uint256 public stakerReceived;   // KITTEN the staker actually got on claim (== 0)
    uint256 public strandedInGauge;  // KITTEN left stuck in the gauge after claim
    uint256 public lost;             // quantified loss to the staker

    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant REWARD = 1000e18;

    constructor() {
        kitten = new MockKitten();                  // child nonce 1 (profit/marker token)
        nfp = new MockNFP();                        // child nonce 2
        gauge = new CLGauge(address(kitten), nfp);  // child nonce 3 (VULN)
    }

    function run() external {
        // This contract acts as the honest staker.
        address stakerAddr = address(this);

        // staker owns an NFP position
        nfp.mint(stakerAddr, TOKEN_ID);

        // gauge is funded with the KITTEN rewards pool it must pay out
        kitten.mint(address(gauge), REWARD);

        // 1) staker stakes the NFP -> ownership transfers to the gauge
        gauge.stake(TOKEN_ID);
        require(nfp.ownerOf(TOKEN_ID) == address(gauge), "stake did not move ownership");

        // 2) rewards accrue for this NFP
        gauge.notifyReward(TOKEN_ID, REWARD);

        // 3) staker claims — verbatim `_getReward` sends the reward to
        //    nfp.ownerOf == gauge, i.e. the gauge self-transfers to itself.
        uint256 before = kitten.balanceOf(stakerAddr);
        gauge.getReward(TOKEN_ID);
        stakerReceived = kitten.balanceOf(stakerAddr) - before;
        strandedInGauge = kitten.balanceOf(address(gauge));

        // HARM: staker got NOTHING; the full reward is stranded in the gauge.
        require(stakerReceived == 0, "staker unexpectedly received reward");
        require(strandedInGauge == REWARD, "reward not stranded in gauge");

        // mark the quantified loss to SINK (no attacker profit; funds lost)
        lost = REWARD;
        kitten.mint(SINK, lost);
        require(kitten.balanceOf(SINK) == REWARD, "loss not marked");
    }
}
