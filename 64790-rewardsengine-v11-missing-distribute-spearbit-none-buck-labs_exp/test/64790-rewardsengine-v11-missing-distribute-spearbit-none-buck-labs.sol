// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Buck Labs RewardsEngine V1.1 — upgrade drops distribute
    (Spearbit, January 2026, finding 64790).
    SYNTHETIC, cheatcode-free reduction.
    V1.1 is a standalone implementation. The review lists it as
    Initializable, AccessControlUpgradeable, PausableUpgradeable,
    MulticallUpgradeable, UUPSUpgradeable, and not as a child of V1.
    Those bases are omitted. claimFor and batchClaimFor are present.
    distribute is not. The migration runbook calls distribute(uint256)
    and then a user claim. Here that call reverts, the coupon stays in
    the proxy, and claimFor returns 0. */

contract RewardToken {
    string public name = "Coupon USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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

contract RewardsStorage {
    RewardToken public rewardToken;
    address public beneficiary;
    uint256 public pending;
    mapping(address => uint256) public claimable;
}

contract RewardsProxy {
    // EIP-1967-style slot so the implementation pointer does not collide with V1 storage.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function upgradeTo(address next) external {
        bytes32 slot = IMPL_SLOT;
        assembly {
            sstore(slot, next)
        }
    }

    function implementation() public view returns (address impl) {
        bytes32 slot = IMPL_SLOT;
        assembly {
            impl := sload(slot)
        }
    }

    fallback() external payable {
        address impl = implementation();
        require(impl != address(0), "IMPL");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract RewardsEngineV1 is RewardsStorage {
    function initialize(RewardToken token, address user) external {
        rewardToken = token;
        beneficiary = user;
    }

    function fund(uint256 amount) external {
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "FUND");
        pending += amount;
    }

    function distribute(uint256 coupon) external {
        require(coupon > 0 && coupon <= pending, "COUPON");
        pending -= coupon;
        claimable[beneficiary] += coupon;
    }

    function claim() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        claimable[msg.sender] = 0;
        if (amount != 0) require(rewardToken.transfer(msg.sender, amount), "PAY");
        return amount;
    }
}

/// @dev Standalone V1.1. No distribute. Same storage prefix as V1.
contract RewardsEngineV1_1 is RewardsStorage {
    function claimFor(address user, address recipient) external returns (uint256 amount) {
        amount = claimable[user]; // @> VULN: V1.1 has no distribute, so the coupon was never credited
        claimable[user] = 0;
        if (amount != 0) require(rewardToken.transfer(recipient, amount), "PAY");
        return amount;
    }

    function batchClaimFor(address[] calldata users) external returns (uint256 totalClaimed) {
        uint256 n = users.length;
        for (uint256 i = 0; i < n; i++) {
            totalClaimed += claimable[users[i]];
        }
        return totalClaimed;
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    RewardToken public token; // CREATE nonce 1
    RewardsEngineV1 public v1; // CREATE nonce 2
    RewardsEngineV1_1 public v11; // CREATE nonce 3
    RewardsProxy public proxy; // CREATE nonce 4

    uint256 public claimed;
    uint256 public stuck;

    constructor() {
        token = new RewardToken();
        v1 = new RewardsEngineV1();
        v11 = new RewardsEngineV1_1();
        proxy = new RewardsProxy();
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(proxy), N);
        proxy.upgradeTo(address(v1));
        RewardsEngineV1(address(proxy)).initialize(token, msg.sender);
        RewardsEngineV1(address(proxy)).fund(N);
        proxy.upgradeTo(address(v11));
        bytes memory payload = abi.encodeWithSignature("distribute(uint256)", N);
        (bool ok,) = address(proxy).call(payload);
        require(!ok, "distribute still present");
        claimed = RewardsEngineV1_1(address(proxy)).claimFor(msg.sender, msg.sender);
        stuck = token.balanceOf(address(proxy));
        require(claimed == 0, "claim");
        require(stuck == N, "stuck");
        require(token.balanceOf(msg.sender) == 0, "user");
    }
}
