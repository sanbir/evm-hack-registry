// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL ESS — the wrapper never calls WithdrawExpired, distributeYield, or
    WithdrawFees (Cyfrin, finding 66736). SYNTHETIC, cheatcode-free.
    Those three functions revert unless msg.sender is the wrapper, and the
    wrapper has no pass-through. An expired lock-time deposit, its yield, and
    the protocol fee stay in the vault. 1000 + 40 + 25 = 1065 tokens locked. */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Treasury {}

contract Issuer {
    address public wrapper;
    MockToken public token;
    address public treasury;
    uint256 public locked;

    function init(address w, MockToken t, address tre) external {
        wrapper = w;
        token = t;
        treasury = tre;
    }

    function note(uint256 amount) external {
        require(msg.sender == wrapper, "deposit");
        locked = amount;
    }

    function WithdrawExpired(uint256) external {
        require(msg.sender == wrapper, "wrapper"); // @> VULN: only the wrapper may pass, and STBL_ESS_Wrapper1 never calls this
        // FIX: add a wrapper pass-through gated by the admin role
        token.transfer(treasury, locked);
    }
}

contract AssetVault {
    address public wrapper;
    MockToken public token;
    address public treasury;
    uint256 public locked;
    uint256 public fees;
    uint256 public yieldAccrued;
    uint256 public lockEnd;

    function init(address w, MockToken t, address tre) external {
        wrapper = w;
        token = t;
        treasury = tre;
    }

    function note(uint256 amount, uint256 fee, uint256 yld) external {
        require(msg.sender == wrapper, "deposit");
        locked = amount;
        fees = fee;
        yieldAccrued = yld;
        lockEnd = block.timestamp;
    }

    function distributeYield() external {
        require(msg.sender == wrapper, "wrapper"); // S5 no wrapper function reaches distributeYield
        yieldAccrued = 0;
    }

    function WithdrawFees() external {
        require(msg.sender == wrapper, "wrapper"); // S6 fees cannot be swept to the treasury
        token.transfer(treasury, fees);
    }
}

contract Wrapper {
    MockToken public token;
    Issuer public issuer;
    AssetVault public vault;
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant FEE = 40 ether;
    uint256 public constant YIELD = 25 ether;

    constructor(MockToken t, Issuer i, AssetVault v) {
        token = t;
        issuer = i;
        vault = v;
    }

    function deposit() external {
        token.transferFrom(msg.sender, address(vault), AMOUNT); // S2
        token.transferFrom(msg.sender, address(vault), FEE);
        token.mint(address(vault), YIELD);
        issuer.note(AMOUNT);
        vault.note(AMOUNT, FEE, YIELD);
    }

    function withdraw() external {
        require(block.timestamp < vault.lockEnd(), "expired"); // S3 normal exit is closed once the lock has elapsed
    }
}

contract FixedWrapper {
    Issuer public issuer;
    AssetVault public vault;

    constructor(Issuer i, AssetVault v) {
        issuer = i;
        vault = v;
    }

    function withdrawExpired(uint256 id) external {
        issuer.WithdrawExpired(id);
    }

    function distributeYield() external {
        vault.distributeYield();
    }

    function withdrawFees() external {
        vault.WithdrawFees();
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    Treasury public treasury; // nonce 2
    Issuer public issuer; // nonce 3
    AssetVault public vault; // nonce 4
    Wrapper public wrapper; // nonce 5

    constructor() {
        token = new MockToken();
        treasury = new Treasury();
        issuer = new Issuer();
        vault = new AssetVault();
        wrapper = new Wrapper(token, issuer, vault);
        issuer.init(address(wrapper), token, address(treasury));
        vault.init(address(wrapper), token, address(treasury));
        token.mint(address(this), 1040 ether);
        token.approve(address(wrapper), type(uint256).max);
    }

    function run() external {
        wrapper.deposit(); // S1
        (bool live,) = address(wrapper).call(abi.encodeWithSignature("withdraw()"));
        (bool expiredOk,) = address(issuer).call(abi.encodeWithSignature("WithdrawExpired(uint256)", uint256(1)));
        (bool viaWrapper,) = address(wrapper).call(abi.encodeWithSignature("WithdrawExpired(uint256)", uint256(1)));
        (bool yieldOk,) = address(vault).call(abi.encodeWithSignature("distributeYield()"));
        (bool feesOk,) = address(vault).call(abi.encodeWithSignature("WithdrawFees()"));
        require(!live, "withdraw should be closed");
        require(!expiredOk && !viaWrapper, "expired path open");
        require(!yieldOk && !feesOk, "admin path open");
        require(token.balanceOf(address(vault)) == 1065 ether, "1065 locked");
        require(token.balanceOf(address(treasury)) == 0, "treasury got nothing");
        require(vault.locked() == 1000 ether && vault.fees() == 40 ether && vault.yieldAccrued() == 25 ether, "buckets");
    }
}
