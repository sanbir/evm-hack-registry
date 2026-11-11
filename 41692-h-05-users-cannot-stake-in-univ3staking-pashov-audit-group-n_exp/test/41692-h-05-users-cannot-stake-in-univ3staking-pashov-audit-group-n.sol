// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DYAD UniswapV3Staking — stake() cannot receive the LP NFT
    (Pashov Audit Group, H-05).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: stake() pulls the position with safeTransferFrom. That calls
    onERC721Received on UniswapV3Staking, which does not implement it, so the
    transfer reverts and the 1,000,000 liquidity stays with the user, unstaked.
    Vulnerable line preserved verbatim below (@> VULN). */

contract Lp {
    string public constant symbol = "LP";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Note {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

contract PositionManager {
    uint128 public constant LIQUIDITY = 1_000_000;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address spender, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        getApproved[id] = spender;
    }

    function positions(uint256)
        external
        pure
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        liquidity = LIQUIDITY;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "owner");
        require(getApproved[tokenId] == msg.sender, "approved");
        ownerOf[tokenId] = to;
        (bool ok, bytes memory ret) = to.call(
            abi.encodeWithSelector(
                bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")),
                msg.sender,
                from,
                tokenId,
                bytes("")
            )
        );
        require(ok && ret.length >= 32, "UNSAFE_RECIPIENT");
        require(
            bytes4(ret) == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")),
            "UNSAFE_RECIPIENT"
        );
    }
}

contract UniswapV3Staking {
    struct StakeInfo {
        uint256 liquidity;
        uint256 lastRewardTime;
        uint256 tokenId;
        bool isStaked;
    }

    Note public dnft;
    PositionManager public positionManager;
    mapping(uint256 => StakeInfo) public stakes;

    event Staked(address indexed user, uint256 noteId, uint256 tokenId, uint256 liquidity);

    constructor(Note note, PositionManager pm) {
        dnft = note;
        positionManager = pm;
    }

    function stake(uint256 noteId, uint256 tokenId) external {
        require(dnft.ownerOf(noteId) == msg.sender, "You are not the Note owner");

        StakeInfo storage stakeInfo = stakes[noteId];
        require(!stakeInfo.isStaked, "Note already used for staking");

        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        require(liquidity > 0, "No liquidity");

        // @> VULN: safeTransferFrom calls onERC721Received, which this contract does not implement
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);

        stakes[noteId] = StakeInfo({
            liquidity: liquidity,
            lastRewardTime: block.timestamp,
            tokenId: tokenId,
            isStaked: true
        });

        emit Staked(msg.sender, noteId, tokenId, liquidity);
    }
}

contract UniswapV3StakingFixed {
    struct StakeInfo {
        uint256 liquidity;
        uint256 lastRewardTime;
        uint256 tokenId;
        bool isStaked;
    }

    Note public dnft;
    PositionManager public positionManager;
    mapping(uint256 => StakeInfo) public stakes;

    constructor(Note note, PositionManager pm) {
        dnft = note;
        positionManager = pm;
    }

    function onERC721Received(address, address, uint256, bytes calldata) public pure returns (bytes4) {
        return msg.sig;
    }

    function stake(uint256 noteId, uint256 tokenId) external {
        require(dnft.ownerOf(noteId) == msg.sender, "You are not the Note owner");
        require(!stakes[noteId].isStaked, "Note already used for staking");
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        require(liquidity > 0, "No liquidity");
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        stakes[noteId] = StakeInfo({
            liquidity: liquidity,
            lastRewardTime: block.timestamp,
            tokenId: tokenId,
            isStaked: true
        });
    }
}

contract Exploit {
    Lp public lp; // CREATE nonce 1
    Note public note; // CREATE nonce 2
    PositionManager public pm; // CREATE nonce 3
    UniswapV3Staking public staking; // CREATE nonce 4

    constructor() {
        lp = new Lp();
        note = new Note();
        pm = new PositionManager();
        staking = new UniswapV3Staking(note, pm);
        note.mint(address(this), 1);
        pm.mint(address(this), 7);
    }

    function run() external {
        lp.mint(address(this), 1_000_000);
        pm.approve(address(staking), 7);

        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.stake.selector, uint256(1), uint256(7)));

        (uint256 recorded,,, bool isStaked) = staking.stakes(1);
        address holder = pm.ownerOf(7);
        uint256 stuck = lp.balanceOf(address(this));

        require(!ok, "stake did not revert");
        require(holder == address(this), "LP left the user");
        require(recorded == 0 && !isStaked, "position was recorded");
        require(stuck == 1_000_000, "1_000_000 LP not stuck");
        require(pm.LIQUIDITY() == 1_000_000, "liquidity");
    }
}
