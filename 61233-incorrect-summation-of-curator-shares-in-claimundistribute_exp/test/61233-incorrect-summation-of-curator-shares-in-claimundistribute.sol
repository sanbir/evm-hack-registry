// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Suzaku Core finding 61233:
// "Incorrect summation of curator shares in claimUndistributedRewards".
//
// The curator-share summation in claimUndistributedRewards iterates over the
// epoch's vaults and, for EACH vault, adds the curator's *total accumulated*
// share (curatorShares[epoch][curator]). A curator that owns multiple active
// vaults therefore has their whole share counted once per owned vault, which
// inflates totalDistributedShares. The inflated total shrinks the computed
// undistributedRewards, so the REWARDS_DISTRIBUTOR claims FEWER tokens than
// entitled; the deficit stays permanently stranded in the contract.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv (floor division).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

/// @dev Minimal ERC20 double. The reward pool is held by the Rewards contract
///      and paid out to the distributor on claim; the marker token records harm.
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

/// @dev Faithful minimal double for a tokenized vault: exposes owner() (curator).
contract VaultTokenized {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

/// @dev Faithful minimal double for the L1 middleware operator registry.
contract L1Middleware {
    address[] internal operators;

    function setOperators(address[] memory ops) external {
        operators = ops;
    }

    function getAllOperators() external view returns (address[] memory) {
        return operators;
    }
}

/// @dev Faithful minimal double for the middleware vault manager.
contract VaultManager {
    mapping(uint48 => address[]) internal vaults;

    function setVaults(uint48 epoch, address[] memory v) external {
        vaults[epoch] = v;
    }

    function getVaults(uint48 epoch) external view returns (address[] memory) {
        return vaults[epoch];
    }
}

interface IL1Middleware {
    function getAllOperators() external view returns (address[] memory);
}

interface IVaultManager {
    function getVaults(uint48 epoch) external view returns (address[] memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract (verbatim buggy summation inlined from the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract Rewards {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10000;

    IL1Middleware public l1Middleware;
    IVaultManager public middlewareVaultManager;
    MiniToken public rewardsToken;

    mapping(uint48 => mapping(address => uint256)) public operatorShares;
    mapping(uint48 => mapping(address => uint256)) public vaultShares;
    mapping(uint48 => mapping(address => uint256)) public curatorShares;
    mapping(uint48 => uint256) public totalRewardsForEpoch;

    constructor(address mw, address vm_, address token) {
        l1Middleware = IL1Middleware(mw);
        middlewareVaultManager = IVaultManager(vm_);
        rewardsToken = MiniToken(token);
    }

    /// @notice Test setter to pre-populate one epoch's accounting.
    function setEpochData(
        uint48 epoch,
        uint256 totalRewards,
        address[] memory operators,
        uint256[] memory opShares,
        address[] memory vaults,
        uint256[] memory vShares,
        address[] memory curators,
        uint256[] memory cShares
    ) external {
        totalRewardsForEpoch[epoch] = totalRewards;
        for (uint256 i = 0; i < operators.length; i++) {
            operatorShares[epoch][operators[i]] = opShares[i];
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            vaultShares[epoch][vaults[i]] = vShares[i];
        }
        for (uint256 i = 0; i < curators.length; i++) {
            curatorShares[epoch][curators[i]] = cShares[i];
        }
    }

    function claimUndistributedRewards(uint48 epoch, address recipient) external returns (uint256) {
        uint256 totalRewardsForEpochValue = totalRewardsForEpoch[epoch];

        // Calculate total distributed shares for the epoch
        uint256 totalDistributedShares = 0;

        // Sum operator shares
        address[] memory operators = l1Middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            totalDistributedShares += operatorShares[epoch][operators[i]];
        }

        // Sum vault shares
        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vaults.length; i++) {
            totalDistributedShares += vaultShares[epoch][vaults[i]];
        }

        // Sum curator shares
        for (uint256 i = 0; i < vaults.length; i++) {
            address curator = VaultTokenized(vaults[i]).owner();
            totalDistributedShares += curatorShares[epoch][curator]; // @> counts each curator once PER OWNED VAULT, inflating the total
        }

        uint256 undistributedRewards =
            totalRewardsForEpochValue - Math.mulDiv(totalRewardsForEpochValue, totalDistributedShares, BASIS_POINTS_DENOMINATOR);

        rewardsToken.transfer(recipient, undistributedRewards);
        return undistributedRewards;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: curator shares summed once per UNIQUE curator.
// ─────────────────────────────────────────────────────────────────────────────
contract RewardsFixed {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10000;

    IL1Middleware public l1Middleware;
    IVaultManager public middlewareVaultManager;
    MiniToken public rewardsToken;

    mapping(uint48 => mapping(address => uint256)) public operatorShares;
    mapping(uint48 => mapping(address => uint256)) public vaultShares;
    mapping(uint48 => mapping(address => uint256)) public curatorShares;
    mapping(uint48 => uint256) public totalRewardsForEpoch;

    constructor(address mw, address vm_, address token) {
        l1Middleware = IL1Middleware(mw);
        middlewareVaultManager = IVaultManager(vm_);
        rewardsToken = MiniToken(token);
    }

    function setEpochData(
        uint48 epoch,
        uint256 totalRewards,
        address[] memory operators,
        uint256[] memory opShares,
        address[] memory vaults,
        uint256[] memory vShares,
        address[] memory curators,
        uint256[] memory cShares
    ) external {
        totalRewardsForEpoch[epoch] = totalRewards;
        for (uint256 i = 0; i < operators.length; i++) {
            operatorShares[epoch][operators[i]] = opShares[i];
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            vaultShares[epoch][vaults[i]] = vShares[i];
        }
        for (uint256 i = 0; i < curators.length; i++) {
            curatorShares[epoch][curators[i]] = cShares[i];
        }
    }

    function claimUndistributedRewards(uint48 epoch, address recipient) external returns (uint256) {
        uint256 totalRewardsForEpochValue = totalRewardsForEpoch[epoch];

        uint256 totalDistributedShares = 0;

        address[] memory operators = l1Middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            totalDistributedShares += operatorShares[epoch][operators[i]];
        }

        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vaults.length; i++) {
            totalDistributedShares += vaultShares[epoch][vaults[i]];
        }

        // FIX: count each unique curator exactly once.
        address[] memory seen = new address[](vaults.length);
        uint256 seenCount = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            address curator = VaultTokenized(vaults[i]).owner();
            bool counted = false;
            for (uint256 j = 0; j < seenCount; j++) {
                if (seen[j] == curator) {
                    counted = true;
                    break;
                }
            }
            if (!counted) {
                seen[seenCount] = curator;
                seenCount++;
                totalDistributedShares += curatorShares[epoch][curator];
            }
        }

        uint256 undistributedRewards =
            totalRewardsForEpochValue - Math.mulDiv(totalRewardsForEpochValue, totalDistributedShares, BASIS_POINTS_DENOMINATOR);

        rewardsToken.transfer(recipient, undistributedRewards);
        return undistributedRewards;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: one curator owns two active vaults, so its share is
// double-counted, shrinking the distributor's claim. The under-claimed deficit
// is stranded in the contract; we record it on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant OPERATOR = 0x0000000000000000000000000000000000000a11;
    address internal constant CURATOR = 0x0000000000000000000000000000000000000C0C;
    address internal constant DISTRIBUTOR = 0x00000000000000000000000000000000000D1517;

    uint48 internal constant EPOCH = 1;
    uint256 internal constant TOTAL_REWARDS = 100_000 ether;

    // Exposed results.
    uint256 public buggyClaimed;
    uint256 public correctClaimed;
    uint256 public strandedDeficit;
    uint256 public sinkMarkerBalance;
    address public rewardsAddr;
    address public markerAddr;

    function run() external payable {
        // --- create every helper unconditionally, fixed order (marker LAST) ---
        MiniToken reward = new MiniToken("Reward", "RWD");        // nonce 1
        VaultTokenized v1 = new VaultTokenized(CURATOR);          // nonce 2
        VaultTokenized v2 = new VaultTokenized(CURATOR);          // nonce 3
        L1Middleware mw = new L1Middleware();                     // nonce 4
        VaultManager vmgr = new VaultManager();                   // nonce 5
        Rewards rewards = new Rewards(address(mw), address(vmgr), address(reward)); // nonce 6
        MiniToken marker = new MiniToken("Marker", "MARK");       // nonce 7 (LAST)

        rewardsAddr = address(rewards);
        markerAddr = address(marker);

        // --- wire up registries ---
        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        mw.setOperators(operators);

        address[] memory vaults = new address[](2);
        vaults[0] = address(v1);
        vaults[1] = address(v2);
        vmgr.setVaults(EPOCH, vaults);

        // --- pre-populate one epoch of share accounting ---
        // operator: 1000 bp; each vault: 2000 bp; curator total (once): 1000 bp
        // Correct sum = 1000 + 4000 + 1000 = 6000 bp -> distributed 60% -> undistributed 40%.
        // Buggy sum   = 1000 + 4000 + (1000*2) = 7000 bp -> claims only 30%.
        uint256[] memory opShares = new uint256[](1);
        opShares[0] = 1000;

        uint256[] memory vShares = new uint256[](2);
        vShares[0] = 2000;
        vShares[1] = 2000;

        address[] memory curators = new address[](1);
        curators[0] = CURATOR;
        uint256[] memory cShares = new uint256[](1);
        cShares[0] = 1000;

        rewards.setEpochData(EPOCH, TOTAL_REWARDS, operators, opShares, vaults, vShares, curators, cShares);

        // --- fund the reward pool held by the contract ---
        reward.mint(address(rewards), TOTAL_REWARDS);

        // --- distributor claims via the BUGGY path (under-claims) ---
        buggyClaimed = rewards.claimUndistributedRewards(EPOCH, DISTRIBUTOR);

        // --- compute the CORRECT undistributed amount (curators counted once) ---
        uint256 correctShares = 1000 /*op*/ + 4000 /*vaults*/ + 1000 /*curator once*/;
        correctClaimed = TOTAL_REWARDS - Math.mulDiv(TOTAL_REWARDS, correctShares, 10000);

        // --- harm: the deficit is stranded in the contract, unclaimable ---
        strandedDeficit = correctClaimed - buggyClaimed;
        marker.mint(SINK, strandedDeficit);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
