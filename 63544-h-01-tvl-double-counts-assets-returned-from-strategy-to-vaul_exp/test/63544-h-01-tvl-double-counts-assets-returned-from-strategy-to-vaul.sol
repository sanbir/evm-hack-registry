// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63544:
// "[H-01] TVL double-counts assets returned from strategy to vault".
//
// When the deposit pool allocates assets to a strategy it increments
// ElytraDepositPoolV1.assetsAllocatedToStrategies[asset]. When the strategy later
// returns those same tokens to the unstaking vault, it calls
// ElytraUnstakingVaultV1.receiveFromStrategy(asset, amount), which ONLY does
// claimableAssets[asset] += amount and NEVER decrements the deposit pool's
// assetsAllocatedToStrategies[asset]. getTotalAssetTVL() sums BOTH
// (strategyAllocated + unstakingVaultBalance), so the returned tokens are counted
// twice: reported TVL = 200e18 while the protocol truly holds only 100e18. The
// inflated TVL inflates the elyAsset price, so users mint/redeem at a wrong price.
//
// The vulnerable functions (ElytraUnstakingVaultV1.receiveFromStrategy and
// ElytraDepositPoolV1.getTotalAssetTVL / _getUnstakingVaultBalance) are inlined
// VERBATIM from the H-01 / H-04 / C-03 finding bodies. Only opaque boundaries
// (ERC20 asset, the config registry, the strategy caller) are minimal faithful
// doubles. No mock stands in for the vulnerable boundary itself.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IElytraUnstakingVault {
    function getClaimableAssets(address asset) external view returns (uint256);
    function receiveFromStrategy(address asset, uint256 amount) external;
}

/// @dev Constant key used by the real ElytraConfig registry, kept verbatim.
library ElytraConstants {
    bytes32 internal constant ELYTRA_UNSTAKING_VAULT = keccak256("ELYTRA_UNSTAKING_VAULT");
}

/// @dev Minimal ERC20 double. Holds the real asset tokens whose movement makes
///      the double-count observable against getTotalAssetTVL().
contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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
}

/// @dev Minimal faithful double for the Elytra config registry: resolves the
///      unstaking-vault contract address by key (as getTotalAssetTVL expects).
contract ElytraConfig {
    mapping(bytes32 => address) internal contracts;

    function setContract(bytes32 key, address value) external {
        contracts[key] = value;
    }

    function getContract(bytes32 key) external view returns (address) {
        return contracts[key];
    }
}

interface IElytraConfig {
    function getContract(bytes32 key) external view returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE unstaking vault. receiveFromStrategy is VERBATIM from the H-01
// finding body: it increments claimableAssets but performs NO matching decrement
// of the deposit pool's assetsAllocatedToStrategies. That omission is the bug.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraUnstakingVaultV1 {
    address public strategy;
    mapping(address => uint256) public claimableAssets;

    event AssetsReceivedFromStrategy(address asset, uint256 amount);

    modifier onlyStrategy() {
        require(msg.sender == strategy, "not strategy");
        _;
    }

    function setStrategy(address _strategy) external {
        strategy = _strategy;
    }

    /// @notice Receives assets from strategy for withdrawal processing
    /// @param asset Asset address
    /// @param amount Amount received
    function receiveFromStrategy(address asset, uint256 amount) external onlyStrategy {
        claimableAssets[asset] += amount; // @> increments vault claimable but never decrements ElytraDepositPoolV1.assetsAllocatedToStrategies -> TVL double-count
        emit AssetsReceivedFromStrategy(asset, amount);
    }

    /// @notice Claimable balance read by ElytraDepositPoolV1._getUnstakingVaultBalance.
    function getClaimableAssets(address asset) external view returns (uint256) {
        return claimableAssets[asset];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED unstaking vault (negative control): receiveFromStrategy ALSO decrements
// the deposit pool's assetsAllocatedToStrategies, per the finding's recommendation
// ("decreasing the assetsAllocatedToStrategies of ElytraDepositPoolV1 when
// receiveFromStrategy is being triggered"). TVL then reports real holdings.
// ─────────────────────────────────────────────────────────────────────────────
interface IElytraDepositPoolDecrement {
    function decreaseStrategyAllocation(address asset, uint256 amount) external;
}

contract ElytraUnstakingVaultV1Fixed {
    address public strategy;
    address public depositPool;
    mapping(address => uint256) public claimableAssets;

    event AssetsReceivedFromStrategy(address asset, uint256 amount);

    modifier onlyStrategy() {
        require(msg.sender == strategy, "not strategy");
        _;
    }

    function setStrategy(address _strategy) external {
        strategy = _strategy;
    }

    function setDepositPool(address _pool) external {
        depositPool = _pool;
    }

    function receiveFromStrategy(address asset, uint256 amount) external onlyStrategy {
        claimableAssets[asset] += amount;
        // FIX: settle the strategy allocation so the returned tokens are not counted twice.
        IElytraDepositPoolDecrement(depositPool).decreaseStrategyAllocation(asset, amount);
        emit AssetsReceivedFromStrategy(asset, amount);
    }

    function getClaimableAssets(address asset) external view returns (uint256) {
        return claimableAssets[asset];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Deposit pool. getTotalAssetTVL and _getUnstakingVaultBalance are VERBATIM from
// the H-04 / C-03 finding bodies. allocateToStrategy / decreaseStrategyAllocation
// are the minimal faithful allocation-tracking surface the finding describes.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraDepositPoolV1 {
    IElytraConfig public elytraConfig;
    mapping(address => uint256) public assetsAllocatedToStrategies;

    constructor(address config) {
        elytraConfig = IElytraConfig(config);
    }

    /// @notice Allocate pool-held assets out to a strategy (tracks the allocation).
    function allocateToStrategy(address asset, address strategyAddr, uint256 amount) external {
        assetsAllocatedToStrategies[asset] += amount;
        IERC20(asset).transfer(strategyAddr, amount);
    }

    /// @notice Settle a strategy allocation when assets come back (used by the FIX).
    function decreaseStrategyAllocation(address asset, uint256 amount) external {
        require(
            msg.sender == elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT),
            "only unstaking vault"
        );
        uint256 tracked = assetsAllocatedToStrategies[asset];
        if (amount <= tracked) {
            assetsAllocatedToStrategies[asset] -= amount;
        } else {
            assetsAllocatedToStrategies[asset] = 0;
        }
    }

    function getTotalAssetTVL(address asset) public view returns (uint256 totalTVL) {
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        uint256 strategyAllocated = assetsAllocatedToStrategies[asset];
        uint256 unstakingVaultBalance = _getUnstakingVaultBalance(asset);

        return poolBalance + strategyAllocated + unstakingVaultBalance;
    }

    function _getUnstakingVaultBalance(address asset) internal view returns (uint256 balance) {
        address unstakingVault = elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT);
        if (unstakingVault == address(0)) {
            return 0;
        }

        try IElytraUnstakingVault(unstakingVault).getClaimableAssets(asset) returns (uint256 claimableAmount) {
            return claimableAmount;
        } catch {
            return 0;
        }
    }
}

/// @dev Minimal faithful strategy caller: holds allocated assets, then returns
///      them to the unstaking vault via receiveFromStrategy (the real return path).
contract ElytraStrategyStub {
    function returnToVault(address asset, address vault, uint256 amount) external {
        IERC20(asset).transfer(vault, amount);
        IElytraUnstakingVault(vault).receiveFromStrategy(asset, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: allocate 100e18 to a strategy, have the strategy return all
// 100e18 to the unstaking vault via the verbatim receiveFromStrategy, then read
// getTotalAssetTVL(). Buggy path reports 200e18 while the protocol truly holds
// 100e18 (pool+vault ERC20). The 100e18 phantom over-report is recorded on a
// MARKER token minted to the SINK. Fixed path reports the true 100e18.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant ALLOCATION = 100 ether;

    // Exposed results for the driver / Playground.
    uint256 public buggyTVL;
    uint256 public realHoldings;
    uint256 public fixedTVL;
    uint256 public overReport;
    uint256 public sinkMarkerBalance;

    address public buggyVaultAddr;
    address public buggyPoolAddr;
    address public buggyAssetAddr;
    uint256 public buggyStrategyAllocated;
    uint256 public buggyVaultClaimable;
    address public fixedVaultAddr;
    address public fixedPoolAddr;
    address public markerAddr;

    function run() external payable {
        // ── BUGGY scenario ──────────────────────────────────────────────────
        MiniToken assetB = new MiniToken("Asset", "AST");            // nonce 1
        ElytraConfig configB = new ElytraConfig();                   // nonce 2
        ElytraDepositPoolV1 poolB = new ElytraDepositPoolV1(address(configB)); // nonce 3
        ElytraUnstakingVaultV1 vaultB = new ElytraUnstakingVaultV1();          // nonce 4
        ElytraStrategyStub stratB = new ElytraStrategyStub();        // nonce 5

        configB.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vaultB));
        vaultB.setStrategy(address(stratB));

        // pool starts holding 100e18; allocate all of it to the strategy.
        assetB.mint(address(poolB), ALLOCATION);
        poolB.allocateToStrategy(address(assetB), address(stratB), ALLOCATION);
        // strategy returns everything to the unstaking vault via the buggy path.
        stratB.returnToVault(address(assetB), address(vaultB), ALLOCATION);

        buggyPoolAddr = address(poolB);
        buggyVaultAddr = address(vaultB);
        buggyAssetAddr = address(assetB);
        buggyTVL = poolB.getTotalAssetTVL(address(assetB));
        realHoldings = assetB.balanceOf(address(poolB)) + assetB.balanceOf(address(vaultB));
        overReport = buggyTVL - realHoldings;
        // the two mismatched contributors: allocation never settled + claimable both = 100e18.
        buggyStrategyAllocated = poolB.assetsAllocatedToStrategies(address(assetB));
        buggyVaultClaimable = vaultB.getClaimableAssets(address(assetB));

        // ── FIXED scenario (negative control) ───────────────────────────────
        MiniToken assetF = new MiniToken("Asset", "AST");            // nonce 6
        ElytraConfig configF = new ElytraConfig();                   // nonce 7
        ElytraDepositPoolV1 poolF = new ElytraDepositPoolV1(address(configF)); // nonce 8
        ElytraUnstakingVaultV1Fixed vaultF = new ElytraUnstakingVaultV1Fixed();// nonce 9
        ElytraStrategyStub stratF = new ElytraStrategyStub();        // nonce 10

        configF.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vaultF));
        vaultF.setStrategy(address(stratF));
        vaultF.setDepositPool(address(poolF));

        assetF.mint(address(poolF), ALLOCATION);
        poolF.allocateToStrategy(address(assetF), address(stratF), ALLOCATION);
        stratF.returnToVault(address(assetF), address(vaultF), ALLOCATION);

        fixedPoolAddr = address(poolF);
        fixedVaultAddr = address(vaultF);
        fixedTVL = poolF.getTotalAssetTVL(address(assetF));

        // ── HARM marker ─────────────────────────────────────────────────────
        // Record the phantom over-reported TVL (accounting-corruption delta) at SINK.
        MiniToken marker = new MiniToken("PhantomTVL", "LOCKED-AST"); // nonce 11 (LAST)
        markerAddr = address(marker);
        marker.mint(SINK, overReport);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // Harm holds: buggy TVL strictly exceeds real holdings by the returned amount.
        require(buggyTVL == 200 ether, "buggy TVL not double-counted");
        require(realHoldings == 100 ether, "real holdings mismatch");
        require(overReport == 100 ether, "over-report magnitude mismatch");
        require(fixedTVL == 100 ether, "fixed TVL should equal real holdings");
    }
}
