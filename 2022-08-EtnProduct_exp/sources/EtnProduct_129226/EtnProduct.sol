pragma solidity =0.8.1;

contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor() public {
        owner = msg.sender;
    }


    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }


    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}


interface IEtnShop{
    function canUploadProduct(address to,uint commId, uint shopId) external view returns ( bool);
    function getTokenId(uint commId, uint shopId) external view virtual returns (uint) ;
    function getShopOwner(uint commId, uint shopId) external view returns ( address);
}

interface IERC20{
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFactory {
    function createContract(string calldata name, string calldata symbol, bytes32 salt) external returns (address);
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

contract EtnProduct is  Ownable {
    IEtnShop public etnShop;
    IFactory public factory;
    IUniswapV2Router01 public uniswapV2Router;
    IERC20 public U;

    mapping(uint => address[]) public shopProdListMap;
    mapping(address => Product) public tokenProdMap;
    mapping(address => address) public ownerMap;
    address[] public tokenList;
    uint _totalSupply = 0;
    uint swapAmount = 700000000000000000000000;

    event NewToken(address indexed token);

    struct Product {
        uint price;
        string name;
        string video;
        string logo;
        string qrCode;
        string phone;
        string next;
        uint commId;
        uint shopId;
    }

    constructor(address _etnShop,address _factory,address _u, address _router)public {
        etnShop = IEtnShop(_etnShop);
        factory = IFactory(_factory);
        U = IERC20(_u);
        uniswapV2Router = IUniswapV2Router01(_router);
    }

    function newProduct(uint commId, uint shopId, uint price, string memory name, string memory video ) public {
        bool authed = etnShop.canUploadProduct(msg.sender, commId, shopId);
        require(authed, "no authed");
        uint shopTokenId = etnShop.getTokenId(commId,shopId);
        Product memory p = Product(price,name,video,"","","","",commId, shopId);
        address erc20Addr = factory.createContract( name,  name, bytes32(shopTokenId));
        tokenProdMap[erc20Addr] = p;
        shopProdListMap[shopTokenId].push(erc20Addr);
        ownerMap[erc20Addr] = msg.sender;
        _totalSupply++;
        tokenList.push(erc20Addr);

        addLiquidity(erc20Addr);
        emit NewToken(erc20Addr);
    }

    // VULNERABILITY: Unauthorized Protocol Liquidity Seeding + LP Recipient Misdirection
    // Root cause: newProduct() allows any caller who passes the weak `canUploadProduct` check
    // (which only requires owning a shop NFT for the (commId, shopId) that can be self-acquired
    // for a small fee via public comm-NFT mint + invite + shop-mint costing ~1998 USDT + BNB)
    // to cause EtnProduct to CREATE a fresh product ERC20 (via factory using shopTokenId salt)
    // and then call addLiquidity() which donates `swapAmount` (700k * 1e18 default) of the
    // PROTOCOL's own U tokens + equivalent new tokens into a new PancakeSwap pair.
    // Critically, the LP tokens are minted to `msg.sender` (the attacker) rather than locked
    // to the protocol (see commented `// owner,` and passed `msg.sender` below).
    // The EtnProduct contract must hold sufficient U (pre-funded by protocol) for the
    // router's transferFrom(msg.sender=EtnProduct, pair, amountU) to succeed.
    // Code ref: L102 (newProduct calls add), L118-135 (addLiquidity), L125-134 (addLiquidity call),
    // L97 (U state), L79 (swapAmount), L107 (create), L109 (ownerMap set to caller).
    // Why it works: No access control tying product creation to privileged actors; auth is
    // purchasable NFT ownership; LP recipient is attacker-controlled; no minimum lock or
    // protocol-retained LP; product token supply is emitted to EtnProduct then effectively
    // claimable. Attacker can then remove the liquidity they "own".
    // Impact: Direct theft of protocol U reserves (sold via UMarket for BUSDT profit).
    // EXPLOIT STEPS:
    // 1. Acquire comm NFT (public payable mintETN) and self-invite + shop-mint(commId, name, logo) paying mintCost to obtain shop NFT ownership for chosen (commId, shopId=0).
    // 2. Call newProduct(commId, 0, price, name, video) -- passes authed check, creates product token, seeds 700k U + 700k T into pair, LP minted to caller.
    // 3. Immediately: LP.transfer(pair, LP_amount); pair.burn(attacker) -- extracts the full reserves (U + T) because burn uses balanceOf[pair] as liquidity.
    // 4. Sell recovered U via UMarket.saleU() for USDT (using the OTC pricing).
    // 5. Repay flashloan, net profit ~3074 USD.
    function addLiquidity(address token) private {
        if(address(uniswapV2Router) == address (0)){
            return;
        }
        U.approve(address(uniswapV2Router), swapAmount);
        IERC20(token).approve( address(uniswapV2Router), swapAmount);

        uniswapV2Router.addLiquidity(
            address (U),
            token,
            swapAmount,
            swapAmount,
            swapAmount,
            swapAmount,
//            owner,
            msg.sender,
            block.timestamp
        );
    }

    function updateProduct(address erc20Addr, string memory name, string memory video,
        string memory logo, string memory qrCode, string memory phone, string memory next, uint price) public {
        Product storage p = tokenProdMap[erc20Addr];
        bool authed = etnShop.canUploadProduct(msg.sender, p.commId, p.shopId);
        require(authed, "no authed");
//        p.name = name;
        p.video = video;
        p.logo = logo;
        p.qrCode = qrCode;
        p.phone = phone;
        p.next = next;
        p.price = price;
    }

    function transferTo(address to, address erc20Addr) public {
        require(isOwner(msg.sender, erc20Addr));
        ownerMap[erc20Addr] = to;
    }

    //name, logo,price
    function getShopProducts(uint commId, uint shopId) public view returns (address[] memory erc20Addrs, string[] memory,string[] memory,uint[] memory){
        uint shopTokenId = etnShop.getTokenId(commId,shopId);
        uint len = shopProdListMap[shopTokenId].length;

        address[] memory erc20Addrs= new address[](len);
        string[] memory names = new string[](len);
        string[] memory logos = new string[](len);
        uint[] memory prices = new uint[](len);

        for (uint i = 0; i < len; i++) {
            address erc20Addr = shopProdListMap[shopTokenId][i];
            Product memory p = tokenProdMap[erc20Addr];
            erc20Addrs[i] = erc20Addr;
            names[i] = p.name;
            logos[i] = p.logo;
            prices[i] = p.price;
        }
        return (erc20Addrs,names,logos,prices);
    }

    function isOwner(address to, address erc20Addr) public view returns (bool){
        return ownerMap[erc20Addr] == to;
    }

    function totalSupply() external view returns (uint256){
        return _totalSupply;
    }

    function withdrawToken(address _token, address _to,uint256 _amount) public onlyOwner {
        require(_amount > 0, "!zero input");
        IERC20 token = IERC20(_token);
        uint balanced = token.balanceOf(address(this));
        require(balanced >= _amount, "!balanced");
        token.transfer( _to, _amount);
    }

    function setRouter(address _addr) public onlyOwner {
        uniswapV2Router = IUniswapV2Router01(_addr);
    }

    function setU(address _U) public onlyOwner {
        U = IERC20(_U);
    }

    function setSwapAmount(uint _value) public onlyOwner {
        swapAmount = _value;
    }
}