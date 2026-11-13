// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Centrifuge TransferProxy — transferAssets pulls from the proxy, but the
    proxy never approves PoolManager (Spearbit, Centrifuge, July 2024).
    Tokens sent into the proxy cannot be forwarded. run() does not warp. */

contract Asset {
    string public name = "RWA";
    string public symbol = "RWA";
    uint8 public decimals = 18;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) return false;
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TransferProxy {
    function approve(address token, address spender, uint256 amount) external {
        require(Asset(token).approve(spender, amount), "approve");
    }
}

contract Escrow {
    function balance(address token) external view returns (uint256) {
        return Asset(token).balanceOf(address(this));
    }
}

contract PoolManager {
    TransferProxy public proxy;
    Escrow public escrow;

    constructor(TransferProxy proxy_, Escrow escrow_) {
        proxy = proxy_;
        escrow = escrow_;
    }

    function transferAssets(address asset, uint256 amount) external virtual returns (bool pulled) {
        // @> VULN: the proxy has no allowance for PoolManager, so the pull cannot succeed
        pulled = Asset(asset).transferFrom(address(proxy), address(escrow), amount);
    }
}

contract PoolManagerFixed is PoolManager {
    constructor(TransferProxy proxy_, Escrow escrow_, address asset) PoolManager(proxy_, escrow_) {
        proxy_.approve(asset, address(this), type(uint256).max);
    }

    function transferAssets(address asset, uint256 amount) external override returns (bool pulled) {
        pulled = Asset(asset).transferFrom(address(proxy), address(escrow), amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1_000_000 ether;

    Asset public asset;
    TransferProxy public proxy;
    Escrow public escrow;
    PoolManager public manager;
    uint256 public sent;
    bool public pulled;
    uint256 public stuck;
    uint256 public escrowBalance;

    constructor() {
        asset = new Asset();
        proxy = new TransferProxy();
        escrow = new Escrow();
        manager = new PoolManager(proxy, escrow);
    }

    function run() external {
        asset.mint(address(this), AMOUNT);
        require(asset.transfer(address(proxy), AMOUNT), "send");
        sent = asset.balanceOf(address(proxy));
        pulled = manager.transferAssets(address(asset), AMOUNT);
        stuck = asset.balanceOf(address(proxy));
        escrowBalance = asset.balanceOf(address(escrow));
        require(sent == AMOUNT, "sent");
        require(pulled == false, "pulled");
        require(stuck == AMOUNT, "stuck");
        require(escrowBalance == 0, "escrow");
        require(asset.allowance(address(proxy), address(manager)) == 0, "allowance");
    }
}
