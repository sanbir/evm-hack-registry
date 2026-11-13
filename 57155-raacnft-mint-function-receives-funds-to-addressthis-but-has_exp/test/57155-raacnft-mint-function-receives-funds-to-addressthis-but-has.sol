// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAACNFT.mint (CodeHawks 2025-02, finding 57155)
    The buyer pays crvUSD into the NFT contract. Overpayment is refunded.
    The price itself stays at address(this). IRAACNFT has no transfer, approve,
    or sweep, so the price is locked. The PoC price is 5e18 paid with 7e18.

    CREATE order inside Exploit:
      nonce 1 Token, 2 HousePrices, 3 RAACNFT
*/

contract Token {
    string public symbol = "crvUSD";
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

    function safeTransfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function safeTransferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HousePrices {
    mapping(uint256 => uint256) public priceOf;

    function setHousePrice(uint256 tokenId, uint256 price) external {
        priceOf[tokenId] = price;
    }

    function tokenToHousePrice(uint256 tokenId) external view returns (uint256) {
        return priceOf[tokenId];
    }
}

contract RAACNFT {
    Token public token;
    HousePrices public raac_hp;
    mapping(uint256 => address) public ownerOf;
    error RAACNFT__HousePrice();
    error RAACNFT__InsufficientFundsMint();
    event NFTMinted(address indexed minter, uint256 tokenId, uint256 price);

    constructor(Token _token, HousePrices _hp) {
        token = _token;
        raac_hp = _hp;
    }

    function mint(uint256 _tokenId, uint256 _amount) public {
        uint256 price = raac_hp.tokenToHousePrice(_tokenId);
        if (price == 0) revert RAACNFT__HousePrice();
        if (price > _amount) revert RAACNFT__InsufficientFundsMint();
        // @> VULN: mint price is pulled to address(this) and nothing in the contract can withdraw or forward it
        token.safeTransferFrom(msg.sender, address(this), _amount);
        _safeMint(msg.sender, _tokenId);
        if (_amount > price) {
            uint256 refundAmount = _amount - price;
            token.safeTransfer(msg.sender, refundAmount);
        }
        emit NFTMinted(msg.sender, _tokenId, price);
    }

    function _safeMint(address to, uint256 tokenId) internal {
        ownerOf[tokenId] = to;
    }
}

contract RAACNFTFixed {
    Token public token;
    HousePrices public raac_hp;
    address public receiver;
    mapping(uint256 => address) public ownerOf;
    error RAACNFT__HousePrice();
    error RAACNFT__InsufficientFundsMint();

    constructor(Token _token, HousePrices _hp, address _receiver) {
        token = _token;
        raac_hp = _hp;
        receiver = _receiver;
    }

    function mint(uint256 _tokenId, uint256 _amount) public {
        uint256 price = raac_hp.tokenToHousePrice(_tokenId);
        if (price == 0) revert RAACNFT__HousePrice();
        if (price > _amount) revert RAACNFT__InsufficientFundsMint();
        token.safeTransferFrom(msg.sender, receiver, price);
        ownerOf[_tokenId] = msg.sender;
    }
}

contract Exploit {
    Token public token;
    HousePrices public oracle;
    RAACNFT public nft;
    uint256 public locked;

    constructor() {
        token = new Token();
        oracle = new HousePrices();
        nft = new RAACNFT(token, oracle);
        token.mint(address(this), 7 ether);
    }

    function run() external {
        oracle.setHousePrice(2, 5 ether);
        token.approve(address(nft), 7 ether);
        nft.mint(2, 7 ether);
        locked = token.balanceOf(address(nft));
        require(locked == 5 ether, "locked");
        require(token.balanceOf(address(this)) == 2 ether, "refund");
        require(nft.ownerOf(2) == address(this), "owner");
    }
}
