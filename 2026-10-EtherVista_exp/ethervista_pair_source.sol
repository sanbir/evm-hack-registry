pragma solidity =0.5.16;

interface IEtherVistaPair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);
    
    function setMetadata(string calldata website, string calldata image, string calldata description, string calldata chat, string calldata social) external;
    function fetchMetadata() external view returns(string memory, string memory, string memory, string memory, string memory);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function updateProvider(address user) external;
    function euler(uint) external view returns (uint256);
    function viewShare() external view returns (uint256 share);
    function claimShare() external;
    function poolBalance() external view returns (uint);
    function totalCollected() external view returns (uint);
    
    function updateProtocol(address) external;
    function setProtocol() external;
    function protocol() external view returns (address);
    function payableProtocol() external view returns (address payable origin);

    function creator() external view returns (address);
    function renounce() external;

    function setFees() external;
    function updateFees(uint8, uint8, uint8, uint8) external;
    function buyLpFee() external view returns (uint8);
    function sellLpFee() external view returns (uint8);
    function buyProtocolFee() external view returns (uint8);
    function sellProtocolFee() external view returns (uint8);
    function buyTotalFee() external view returns (uint8);
    function sellTotalFee() external view returns (uint8);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function first_mint(address to, uint8 buyLp, uint8 sellLp, uint8 buyProtocol, uint8 sellProtocol, address protocolAddress) external returns (uint liquidity);   
    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address _token0, address _token1) external;
}

interface IEtherVistaERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

interface IEtherVistaFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function routerSetter() external view returns (address);
    function router() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
    function setRouterSetter(address) external;
    function setRouter(address) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

library Math {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

contract EtherVistaERC20 is IEtherVistaERC20 {
    using SafeMath for uint;

    string public constant name = 'VISTA';
    string public constant symbol = 'VISTA-LP';
    uint8 public constant decimals = 18;
    uint public totalSupply;
    address public factory;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        factory = msg.sender;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function transfer(address to, uint value) external returns (bool) {
        if (to != 0x000000000000000000000000000000000000dEaD) {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        }
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint value) external returns (bool) {
        require(spender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'EtherVista: EXPIRED');
        require(spender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'EtherVista: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}

contract EtherVistaPair is IEtherVistaPair, EtherVistaERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    uint256 private bigNumber = 10**20; //prevents liqFee/totalSupply from rounding to 0.
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint8 public buyLpFee;
    uint8 public sellLpFee;
    uint8 public buyProtocolFee; 
    uint8 public sellProtocolFee;
    uint8 public buyTotalFee;
    uint8 public sellTotalFee;

    uint256 public startTime_fees = 0; 
    uint8 public future_buyLpFee;
    uint8 public future_sellLpFee;
    uint8 public future_buyProtocolFee;
    uint8 public future_sellProtocolFee ;

    uint256 public totalCollected;
    uint public poolBalance;

    uint256 public startTime_protocol = 0;
    address public protocol;
    address public future_protocol;

    address public creator; 
    uint256 public creation_time; 

    string public websiteUrl = "Null";
    string public imageUrl = "Null"; //IPFS link
    string public tokenDescription = "Null";
    string public chatUrl = "Null";
    string public socialUrl = "Null";

    struct Provider {
        uint256 lp;
        uint256 euler0;
    }

    uint256[] public euler; 
    mapping(address => Provider) public Providers;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'EtherVista: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //called everytime a swap is performed
    function() external payable {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        poolBalance += msg.value;
        totalCollected += msg.value;
        updateEuler(msg.value);
    }

    //updates the euler constant - occurs everytime a swap is performed
    function updateEuler(uint256 liqFee) internal { 
        if (euler.length == 0){
            euler.push((liqFee*bigNumber)/totalSupply);
        }else{
            euler.push(euler[euler.length - 1] + (liqFee*bigNumber)/totalSupply); 
        }
    }

    //called everytime liquidity is added/removed by the user
    function updateProvider(address user) external  { 
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        if (euler.length == 0){
            Providers[user] = Provider(balanceOf[user], 0); 
        }else{
            Providers[user] = Provider(balanceOf[user], euler[euler.length - 1]);
        }
    }

    function claimShare() public lock {
        require(euler.length > 0, 'EtherVistaPair: Nothing to Claim');
        uint256 share = (Providers[msg.sender].lp * (euler[euler.length - 1] - Providers[msg.sender].euler0))/bigNumber;
        Providers[msg.sender] = Provider(balanceOf[msg.sender], euler[euler.length - 1]);
        poolBalance -= share;
        (bool sent,) = msg.sender.call.value(share)("");
        require(sent, "Failed to send Ether"); 
    }
    
    function viewShare() public view returns (uint256 share) {
        if (euler.length == 0){
            return 0;
        }else{
            return Providers[msg.sender].lp * (euler[euler.length - 1] - Providers[msg.sender].euler0)/bigNumber;
        }
    }

    function updateFees(uint8 buyLpFuture, uint8 sellLpFuture, uint8 buyProtocolFuture, uint8 sellProtocolFuture) external {
        require(msg.sender == creator);
        startTime_fees = block.timestamp;
        future_buyLpFee = buyLpFuture;  
        future_sellLpFee = sellLpFuture;  
        future_buyProtocolFee = buyProtocolFuture;
        future_sellProtocolFee = sellProtocolFuture;
    }

    function setFees() external {
        require(startTime_fees != 0);
        require(msg.sender == creator && block.timestamp - startTime_fees >= 3 days);
        buyLpFee = future_buyLpFee;
        sellLpFee = future_sellLpFee;
        buyProtocolFee = future_buyProtocolFee;
        sellProtocolFee = future_sellProtocolFee;
        buyTotalFee =  future_buyLpFee + future_buyProtocolFee + 1;
        sellTotalFee = future_sellLpFee + future_sellProtocolFee + 1;
    }

    function updateProtocol(address protocolFuture) external {
        require(msg.sender == creator);
        startTime_protocol = block.timestamp;
        future_protocol = protocolFuture;
    }

    function setProtocol() external {
        require(startTime_protocol != 0);
        require(msg.sender == creator && block.timestamp - startTime_protocol >= 3 days);
        protocol = future_protocol;
    }

    function payableProtocol() external view returns (address payable) {
        return address(uint160(protocol));
    }

    function setMetadata(string calldata website, string calldata image, string calldata description, string calldata chat, string calldata social) external {
        require(msg.sender == creator);
        websiteUrl = website;
        imageUrl = image;
        tokenDescription = description;
        chatUrl = chat;
        socialUrl = social;
    }

    function fetchMetadata() public view returns(string memory, string memory, string memory, string memory, string memory) {
        return (websiteUrl, imageUrl, tokenDescription, chatUrl, socialUrl);
    }

    function renounce() external {
        require(msg.sender == creator);
        creator = 0x000000000000000000000000000000000000dEaD;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'EtherVista: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'EtherVistaPair: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'EtherVistaPair: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k). This will never be on.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IEtherVistaFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function first_mint(address to, uint8 buyLp, uint8 sellLp, uint8 buyProtocol, uint8 sellProtocol, address protocolAddress) external lock returns (uint liquidity) {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        require(_totalSupply == 0);
        liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
        _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens

        creator = to;
        creation_time = block.timestamp;
        protocol = protocolAddress;
        buyLpFee = buyLp;
        sellLpFee = sellLp;
        buyProtocolFee = buyProtocol;
        sellProtocolFee = sellProtocol;
        buyTotalFee =  buyLp + buyProtocol + 1;
        sellTotalFee = sellLp + sellProtocol + 1;
        
        require(liquidity > 0, 'EtherVistaPair: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            revert('Use first_mint instead');
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'EtherVistaPair: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');   
        require(block.timestamp - creation_time >= 5 days, 'EtherVistaPair: FORBIDDEN RUGPULL');

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'EtherVistaPair: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(msg.sender == IEtherVistaFactory(factory).router(), 'EtherVistaPair: FORBIDDEN');
        require(amount0Out > 0 || amount1Out > 0, 'EtherVistaPair: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'EtherVista: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'EtherVistaPair: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'EtherVista: INSUFFICIENT_INPUT_AMOUNT');
        { 
        require(balance0 * balance1 >= reserve0 * reserve1, "K");
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
