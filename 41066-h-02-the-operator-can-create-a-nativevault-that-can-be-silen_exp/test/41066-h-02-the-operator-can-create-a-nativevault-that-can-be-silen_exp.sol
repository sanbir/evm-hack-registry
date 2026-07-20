// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/*
    Karak — [H-02] The operator can create a `NativeVault` that can be silently unslashable
    Code4rena 2024-07-karak, finding id 41066.

    Root cause: when an operator deploys a NativeVault via `Core.deployVaults()`, the
    operator-supplied `extraData` (manager, slashStore, nodeImplementation) is stored on the
    vault with NO input validation. During slashing, `Core`/`SlasherLib` calls the vault with
    the protocol's whitelisted slashing handler for the asset (`assetSlashingHandlers[asset]`),
    but `NativeVault.slashAssets()` reverts unless that handler equals the operator-chosen
    `slashStore`. By setting `slashStore` to any address other than the whitelisted ETH
    handler, the operator makes `slashAssets()` revert forever -> the vault is permanently
    unslashable, so a misbehaving operator's stake can never be penalized.

    This is a faithful, self-contained reduction: the vulnerable check and the missing
    input validation are preserved verbatim; only the minimal surrounding machinery
    (asset tracking, deploy loop, slashing loop) is inlined.
*/

/// @dev Custom error preserved from NativeVault.
error NotSlashStore();

/// @dev Minimal faithful reduction of Karak's NativeVault.
///      Tracks staked native-ETH assets and is slashable by its owner (the Core contract).
contract NativeVault {
    struct State {
        address slashStore; // operator-controlled; set at init with NO validation
        address manager; // operator-controlled; set at init with NO validation
        uint256 totalAssets; // staked assets subject to slashing
    }

    State internal _s;
    address public core; // owner: the Core contract that deployed this vault
    address public asset;
    bool private _initialized;

    function _state() internal view returns (State storage) {
        return _s;
    }

    modifier onlyOwner() {
        require(msg.sender == core, "not owner");
        _;
    }

    /// @notice Deployed and initialized by `Core.deployVaults()`.
    ///         `extraData` is fully operator-controlled and is NOT validated here or in Core.
    function initialize(address _core, address _asset, bytes memory extraData) external {
        require(!_initialized, "init");
        _initialized = true;
        core = _core;
        asset = _asset;
        // @> operator-supplied slashStore is stored verbatim — never checked against the
        //    protocol's whitelisted slashing handler for `asset`. This missing validation
        //    is the root cause: the operator can point slashStore anywhere.
        (address manager, address slashStore,) = abi.decode(extraData, (address, address, address));
        _state().slashStore = slashStore;
        _state().manager = manager;
    }

    /// @notice Models native ETH staked into the vault (subject to slashing).
    function stake(uint256 amount) external {
        _state().totalAssets += amount;
    }

    function totalAssets() external view returns (uint256) {
        return _state().totalAssets;
    }

    /// @notice Called by Core during slashing with the protocol's whitelisted
    ///         `slashingHandler` for the vault's asset (see SlasherLib loop below).
    function slashAssets(uint256 totalAssetsToSlash, address slashingHandler)
        external
        onlyOwner
        returns (uint256 transferAmount)
    {
        State storage self = _state();
        if (slashingHandler != self.slashStore) revert NotSlashStore(); // @> NativeVault.sol:L308
        transferAmount = totalAssetsToSlash;
        self.totalAssets -= transferAmount;
    }
}

/// @dev Minimal faithful reduction of Karak's Core + SlasherLib.
contract Core {
    struct VaultConfig {
        address asset;
        address operator;
        bytes extraData;
    }

    mapping(address asset => address slashingHandler) public assetSlashingHandlers;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Protocol admin whitelists the canonical slashing handler for an asset.
    function allowlistAsset(address asset, address slashingHandler) external {
        require(msg.sender == owner, "not owner");
        assetSlashingHandlers[asset] = slashingHandler;
    }

    /// @notice Operator entrypoint. `extraData` flows straight into the vault's initialize()
    ///         with NO validation of the operator-chosen slashStore.
    function deployVaults(VaultConfig[] memory configs) external returns (address[] memory vaults) {
        vaults = new address[](configs.length);
        for (uint256 i = 0; i < configs.length; i++) {
            NativeVault v = new NativeVault();
            v.initialize(address(this), configs[i].asset, configs[i].extraData);
            vaults[i] = address(v);
        }
    }

    /// @notice Mirrors SlasherLib.slashAssets: passes the whitelisted handler per asset.
    ///         (src/entities/SlasherLib.sol#L134-L138)
    function finalizeSlashing(address[] memory vaults, uint256[] memory earmarkedStakes) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            NativeVault(vaults[i]).slashAssets(
                earmarkedStakes[i], assetSlashingHandlers[NativeVault(vaults[i]).asset()]
            );
        }
    }
}

contract KarakUnslashableVaultTest is Test {
    Core core;

    // Constants.DEAD_BEEF is Karak's placeholder asset id for native ETH.
    address constant ETH = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
    address legitimateHandler = address(0x1111); // whitelisted ETH slashing handler
    address operator = address(0xA11CE);
    address manager = address(0xB0B);
    address nodeImpl = address(0xC0DE);

    function setUp() public {
        core = new Core();
        core.allowlistAsset(ETH, legitimateHandler);
    }

    function _deployVault(address slashStore) internal returns (NativeVault v) {
        Core.VaultConfig[] memory cfgs = new Core.VaultConfig[](1);
        cfgs[0] = Core.VaultConfig({
            asset: ETH,
            operator: operator,
            extraData: abi.encode(manager, slashStore, nodeImpl)
        });
        vm.prank(operator);
        address[] memory vaults = core.deployVaults(cfgs);
        v = NativeVault(vaults[0]);
        v.stake(100 ether); // operator has 100 ETH of stake at risk
    }

    /// @notice Control: an honestly-configured vault (slashStore == whitelisted handler)
    ///         IS slashable — proving the reduction's slashing path actually works.
    function test_honestVault_isSlashable() public {
        NativeVault good = _deployVault(legitimateHandler);

        address[] memory vaults = new address[](1);
        vaults[0] = address(good);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;

        core.finalizeSlashing(vaults, amts);
        assertEq(good.totalAssets(), 90 ether, "honest vault must be slashable");
    }

    /// @notice HARM: the operator sets slashStore to an arbitrary address, so the protocol's
    ///         valid slashing of a misbehaving operator reverts forever and the operator's
    ///         entire stake stays intact — slashing (core protocol security) is defeated.
    function test_createUnslashableVault() public {
        address badSlashStore = address(666); // != legitimateHandler
        NativeVault bad = _deployVault(badSlashStore);

        address[] memory vaults = new address[](1);
        vaults[0] = address(bad);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;

        // Core passes the whitelisted ETH handler; the operator-set slashStore differs,
        // so the vault reverts and the slash cannot be applied.
        vm.expectRevert(NotSlashStore.selector);
        core.finalizeSlashing(vaults, amts);

        // The misbehaving operator's stake is untouched — it can never be penalized.
        assertEq(bad.totalAssets(), 100 ether, "unslashable vault: operator keeps 100% of stake");
    }
}
