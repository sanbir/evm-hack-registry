// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Parallel 3.1 — processSurplus always reverts for managed collateral
    (Cyfrin 2026-03-04, finding #65528)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: LibSurplus computes collateralSurplus from LibManager.totalAssets
    (strategy balance). processSurplus then self-swaps via swapExactInput, and
    Swapper tries transferFrom(msg.sender=diamond, manager, amount). The diamond
    never holds managed collateral (mints go user→manager; burns manager→user),
    so balance is always 0 and the transfer reverts. Strategy yield is permanently
    uncapturable.

    Blamed transferFrom path preserved with @> VULN marker.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "ERC20InsufficientBalance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockManager {
    MockERC20 public immutable asset;

    constructor(MockERC20 a) {
        asset = a;
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev Correct fix path: release surplus to diamond before swap.
    function release(address to, uint256 amount) external {
        require(asset.transfer(to, amount), "release");
    }
}

/// @dev Diamond-like Parallelizer surface: Surplus + Swapper facets combined.
contract Parallelizer {
    MockERC20 public immutable collateral;
    MockManager public manager;
    bool public isManaged;
    uint256 public debtTokenP; // outstanding tokenP liability (in collat units for simplicity)
    uint256 public tokenPMinted;

    constructor(MockERC20 col) {
        collateral = col;
    }

    function setCollateralManager(MockManager m, bool managed) external {
        manager = m;
        isManaged = managed;
    }

    /// @dev Mint path: for managed collat, tokens go user → manager (diamond balance stays 0).
    function mint(uint256 amount) external {
        if (isManaged) {
            require(collateral.transferFrom(msg.sender, address(manager), amount), "to mgr");
        } else {
            require(collateral.transferFrom(msg.sender, address(this), amount), "to diamond");
        }
        debtTokenP += amount;
        tokenPMinted += amount;
    }

    function getCollateralSurplus() public view returns (uint256 surplus) {
        uint256 bal = isManaged ? manager.totalAssets() : collateral.balanceOf(address(this));
        if (bal > debtTokenP) surplus = bal - debtTokenP;
    }

    /// @dev Faithful processSurplus → self swapExactInput path.
    function processSurplus(uint256 /*minOut*/) external returns (uint256) {
        uint256 collateralSurplus = getCollateralSurplus();
        require(collateralSurplus > 0, "no surplus");

        // FIX: if (isManaged) manager.release(address(this), collateralSurplus);

        collateral.approve(address(this), collateralSurplus);
        // self-call: msg.sender inside _swap is the diamond
        return this.swapExactInput(collateralSurplus);
    }

    function swapExactInput(uint256 amountIn) external returns (uint256) {
        return _swap(amountIn);
    }

    function _swap(uint256 amountIn) internal returns (uint256) {
        if (isManaged) {
            // mint path for managed collateral (Swapper L222-225)
            // tries to pull from diamond → manager, but diamond holds 0
            collateral.transferFrom(
                msg.sender, // @> VULN: msg.sender is diamond with 0 managed-collateral balance
                address(manager),
                amountIn
            );
            // FIX: release from manager to diamond before this transferFrom
        } else {
            // unmanaged: diamond already holds tokens
            require(collateral.balanceOf(address(this)) >= amountIn, "bal");
        }
        // Convert surplus to tokenP accounting (simplified: reduce debt)
        if (debtTokenP >= amountIn) debtTokenP -= amountIn;
        else debtTokenP = 0;
        return amountIn;
    }
}

contract Exploit {
    MockERC20 public eurA; // CREATE 1
    MockManager public manager; // CREATE 2
    Parallelizer public parallelizer; // CREATE 3

    bool public processReverts;
    uint256 public surplusStuck;
    uint256 public diamondBal;

    uint256 public constant BASE_6 = 1e6;

    constructor() {
        eurA = new MockERC20("EURC", "EURC");
        manager = new MockManager(eurA);
        parallelizer = new Parallelizer(eurA);
        parallelizer.setCollateralManager(manager, true);
    }

    function run() external {
        // Mint 100 tokenP — tokens flow to manager, diamond holds 0
        eurA.mint(address(this), 100 * BASE_6);
        eurA.approve(address(parallelizer), 100 * BASE_6);
        parallelizer.mint(100 * BASE_6);
        require(eurA.balanceOf(address(parallelizer)) == 0, "diamond should hold 0");

        // Simulate 8% strategy yield on manager
        eurA.mint(address(manager), 8 * BASE_6);

        uint256 surplus = parallelizer.getCollateralSurplus();
        require(surplus == 8 * BASE_6, "surplus should be 8e6");

        // processSurplus reverts — diamond has 0 balance for transferFrom
        (bool ok,) = address(parallelizer).call(
            abi.encodeWithSelector(Parallelizer.processSurplus.selector, uint256(0))
        );
        processReverts = !ok;
        diamondBal = eurA.balanceOf(address(parallelizer));
        surplusStuck = manager.totalAssets() - 100 * BASE_6; // yield still on manager

        // HARM: permanent DoS on surplus processing; yield uncapturable
        require(processReverts, "processSurplus should revert for managed collat");
        require(diamondBal == 0, "diamond still empty");
        require(surplusStuck == 8 * BASE_6, "yield still stuck on manager");
    }
}
