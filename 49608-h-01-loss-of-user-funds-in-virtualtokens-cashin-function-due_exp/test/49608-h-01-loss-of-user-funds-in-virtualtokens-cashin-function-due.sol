// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Lambo VirtualToken.cashIn (Code4rena, 2024-12).
    An ERC20 cash-in pulls `amount` and then mints msg.value.
    msg.value is 0, so the user pays 100 and receives 0 shares.
    The control mints `amount`.
*/

contract Asset {
    string public symbol = "USDT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VirtualToken {
    Asset public asset;
    mapping(address => uint256) public balanceOf;
    uint256 public pulled;
    uint256 public minted;
    uint256 public lastValue;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function cashIn(uint256 amount) external payable {
        pulled = amount;
        asset.transferFrom(msg.sender, address(this), amount);
        lastValue = msg.value;
        _mint(msg.sender, msg.value); // @> VULN: ERC20 cash-in mints msg.value, which is 0
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        minted = amount;
    }
}

contract VirtualTokenFixed {
    Asset public asset;
    mapping(address => uint256) public balanceOf;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function cashIn(uint256 amount) external payable {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }
}

contract LockMarker {
    string public symbol = "LOCKED-ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Asset public asset;
    VirtualToken public token;
    LockMarker public marker;

    function run() external {
        asset = new Asset();
        token = new VirtualToken(asset);
        marker = new LockMarker();
        asset.mint(address(this), AMOUNT);
        asset.approve(address(token), AMOUNT);
        token.cashIn(AMOUNT);
        require(token.balanceOf(address(this)) == 0, "minted 0");
        require(asset.balanceOf(address(token)) == AMOUNT, "100 pulled");
        marker.mint(SINK, AMOUNT);
        require(marker.balanceOf(SINK) == AMOUNT, "100 locked");
    }
}
