// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;
interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value)external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function burn(uint256 amount) external returns (bool);
}
interface PriceGet {
    function buy_current_rate(uint256 _usdtamount) external view returns (uint256);
    function sell_current_rate(uint256 _tokenamount) external view returns (uint256);
    
}

interface Bordmember {
    function collect(address _token,address _user,uint256 _amt) external ;
    function updateMemberRewred(uint256 _amt) external ; //updaterewredusdt
}


interface routeraddress {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
}
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
library Counters {
    struct Counter {
        uint256 _value; // default: 0
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        unchecked {
            counter._value += 1;
        }
    }

    function decrement(Counter storage counter) internal {
        uint256 value = counter._value;
        require(value > 0, "Counter: decrement overflow");
        unchecked {
            counter._value = value - 1;
        }
    }
}

library SafeMath {

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}


interface IERC165 {

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);

     function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function approve(address to, uint256 tokenId) external;

    function setApprovalForAll(address operator, bool _approved) external;

    function getApproved(uint256 tokenId) external view returns (address operator);

    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IERC721Receiver {

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface IERC721Metadata is IERC721 {

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}

library Address {

    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}



library Strings {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    function toString(uint256 value) internal pure returns (string memory) {

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}

abstract contract ERC165 is IERC165 {

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = _NOT_ENTERED;
    }
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (_status == _ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = _NOT_ENTERED;
    }

    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }
}
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
contract LegendaryMoneyMonNft is Context, ERC165, IERC721, IERC721Metadata ,Ownable,ReentrancyGuard{
    using Address for address;
    using Strings for uint256;

    string private _name;
    string private _symbol;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    mapping(uint256 => string) internal _uri;
    string public baseURI ;
    constructor(address _fundcollector) {
        _name = "Legendary MoneyMon NFTs";
        _symbol = "Legendary MON NFT";
        baseURI = "https://moneymon.fun/" ;
        fundcollector = _fundcollector ;
        totalroyaltyaddress = 1 ;
    }
    bool public lockstatus ;
    modifier islick() {
        require(!lockstatus,"Transfer_is_lock");
        _;
    }
    function lock() public onlyOwner {
        lockstatus = false;
    }
    function unlock() public onlyOwner {
        lockstatus = true;
    }
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function balanceOf(address owner) public view virtual override returns (uint256) {
        require(owner != address(0), "ERC721: address zero is not a valid owner");
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: owner query for nonexistent token");
        return owner;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }



    function approve(address to, uint256 tokenId) public virtual override {
        address owner = ownerOf(tokenId);
        require(to != owner, "ERC721: approval to current owner");

        require(
            _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
            "ERC721: approve caller is not owner nor approved for all"
        );

        _approve(to, tokenId);
    }

    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        require(_exists(tokenId), "ERC721: approved query for nonexistent token");

        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public virtual override {
        _setApprovalForAll(_msgSender(), operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");

        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public virtual override {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, data);
    }

    function _safeTransfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal virtual {
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "ERC721: transfer to non ERC721Receiver implementer");
    }

    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        return (spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender);
    }

    function _safeMint(address to, uint256 tokenId) internal virtual {
        _safeMint(to, tokenId, "");
    }

    function _safeMint(
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal virtual {
        _mint(to, tokenId);
        require(
            _checkOnERC721Received(address(0), to, tokenId, data),
            "ERC721: transfer to non ERC721Receiver implementer"
        );
    }

    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "ERC721: mint to the zero address");
        require(!_exists(tokenId), "ERC721: token already minted");

        _beforeTokenTransfer(address(0), to, tokenId);

        _balances[to] += 1;
        _owners[tokenId] = to;
        
        // useridlist[to].push(tokenId);
        // index[tokenId][to] = useridlist[to].length - 1 ;

        emit Transfer(address(0), to, tokenId);

        _afterTokenTransfer(address(0), to, tokenId);
    }
    function burn(uint256 tokenId) public returns (bool){
        require(_exists(tokenId), "ERC721: token already minted");
        address owner = ownerOf(tokenId);
        require(msg.sender == owner, "ERC721: approval to current owner");
        _burn(tokenId);
        return true;
    }
    function _burn(uint256 tokenId) internal virtual {
        address owner = ownerOf(tokenId);

        _beforeTokenTransfer(owner, address(0), tokenId);

        // Clear approvals
        _approve(address(0), tokenId);

        // removeid(tokenId,owner);

        _balances[owner] -= 1;
        delete _owners[tokenId];
        emit Transfer(owner, address(0), tokenId);
        
        _afterTokenTransfer(owner, address(0), tokenId);
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal nonReentrant islick virtual {
        require(ownerOf(tokenId) == from, "ERC721: transfer from incorrect owner");
        require(to != address(0), "ERC721: transfer to the zero address");
        _beforeTokenTransfer(from, to, tokenId);

        // Clear approvals from the previous owner
        _approve(address(0), tokenId);

        // removeid(tokenId,from);
        // useridlist[to].push(tokenId);
        // index[tokenId][to] = useridlist[to].length - 1 ;

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        
        
        emit Transfer(from, to, tokenId);

        _afterTokenTransfer(from, to, tokenId);
    }

    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function _setApprovalForAll(
        address owner,
        address operator,
        bool approved
    ) internal virtual {
        require(owner != operator, "ERC721: approve to caller");
        _operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        if (to.isContract()) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ERC721: transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {}

    uint256 public totaltokenId;
    event onMint(uint256 TokenId, string URI, address creator,string typenft,uint256 callingtime);
    event retopup(uint256 TokenId, string URI, address creator,string typenft,uint256 callingtime);

    mapping (address => uint256) public usernftcount ;
    // uint8 public maxnft = 4 ;
    address public admin = 0xa8cf7AcC731b17e06a0b4c7CC79CE02cD51CfA59;
    address public fundcollector ;
    string[] public nftname = ["","Base_Light_Mon","Base_Fire_Mon","Base_Flam_Mon","Base_Burn_Mon","Base_Flash_Mon","Base_Strom_Mon","Base_Grass_Mon","Base_Stone_Mon","Base_Water_Mon","Base_Ice_Mon"];

    mapping ( address => mapping (uint256 => uint256 ) ) public userTier ;
    uint256[] public tieramount = [500,1000,2000,4000,8000,8000,8000,8000,8000,8000,8000,8000] ;

    
    mapping (uint256 => uint256) public nfttypebyid ;
    mapping (uint256 => uint256 ) public tokenidMinttime ;

    uint256 public USDT_Amt = 500 ether ;
    
    address public usdt = 0x55d398326f99059fF775485246999027B3197955 ;
    address public men = 0xA1C1A7341a1713F174D59926E49E4A1228924100 ;
    uint24 public poolfee = 2500 ;
    address public priceaddress = 0x0e67b5A10f69B2737484C853cF0576eDa85ddDF8 ;
    // address public RouterAddress = 0x44709F82f31d99E8DA3875E4E2396939Bf804b4c ;
    IPancakeV3Router public RouterAddress = IPancakeV3Router(0x1b81D678ffb9C0263b24A97847620C99d213eB14) ;

    uint256 public bordmemberper = 30 ;
    uint256 public mainnftper = 70 ;
    address public bordmember = 0xD8fDf22974220613a3e8a3Ad6446f8Fee054b429 ;
    address public mainnft = address(this) ;

    struct Personal{
        uint256[] nftid;
        string[] nfttype;
    }

    mapping (address => Personal ) internal  PersonalData ;
    function changefundcollector(address _fundcollector) public onlyOwner{
        fundcollector = _fundcollector ;
    }    
    function changeUSDT_Amt(uint256 _USDT_Amt) public onlyOwner{
        USDT_Amt = _USDT_Amt ;
    }  
    function changeadmin(address _admin) public onlyOwner{
        admin = _admin ;
    }
    function generate10Digit(address _user) public view returns (uint) {
        uint _usercount = usernftcount[_user] ;
        if (_usercount == 0){
            uint random = uint(keccak256(abi.encodePacked(
                block.timestamp,
                block.difficulty,
                msg.sender
            ))) % 3 + 1;
            return random;
        }
        else if(_usercount == 1){
            uint random = 4 + (uint(
                keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender))
                ) % 3); // Produces 4, 5, or 6
            return random;
        }
        else if(_usercount == 2){
            uint random = uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender)));
            // Modulo 2 to get either 0 or 1, then add 7 to make it 7 or 8
            return 7 + (random % 2);
        }
        else {
            uint random = uint8(uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender))) % 2);
            return random + 9; // random will be 0 or 1, so return 9 or 10
        }


    }

    function getLastDayStart() public view returns (uint256) {
        // Current timestamp
        uint256 currentTimestamp = block.timestamp;

        // Start of the current day (midnight UTC)
        uint256 currentDayStart = currentTimestamp - (currentTimestamp % 86400);
        // uint256 currentDayEnd = currentDayStart + 86400;
        
        // Start of the last day (midnight UTC of the previous day)
        // uint256 lastDayStart = currentDayStart - 86400;
        
        return currentDayStart;
    }


    function GetPersonalData(address _user) public view returns (uint256[] memory,string[] memory,uint256[] memory,uint256[] memory){
        uint256[] memory _tier = new uint256[](PersonalData[_user].nftid.length);
        uint256[] memory _tiercount = new uint256[](PersonalData[_user].nftid.length);
        for(uint256 i = 0 ; i < PersonalData[_user].nftid.length ; i++){
            uint256 _nid = PersonalData[_user].nftid[i] ;
            _tier[i] = userTier[_user][_nid];
            _tiercount[i] = 0;
        }

        return (PersonalData[_user].nftid,PersonalData[_user].nfttype,_tier,_tiercount);
    }
    function chnageUsdt(address _usdt) public onlyOwner{
        usdt = _usdt;
    }
    function chnagemen(address _men) public onlyOwner{
        men = _men;
    }
    function chnagepriceaddress(address _priceaddress) public onlyOwner{
        priceaddress = _priceaddress;
    }
    function chnageRouterAddress(address _RouterAddress) public onlyOwner{
        RouterAddress = IPancakeV3Router(_RouterAddress);
    }


    function changebordmember(address _bordmember) public onlyOwner {
        bordmember = _bordmember ;
    }

    function changetrymember(address _mainnft) public onlyOwner {
        mainnft = _mainnft ;
    }

    function changetrymemberper(uint256 _mainnftper) public onlyOwner {
        mainnftper = _mainnftper ;
    }

    function changebordmemberper(uint256 _bordmemberper) public onlyOwner {
        bordmemberper = _bordmemberper ;
    }

    function updateMemberRewred(uint _amt) internal{
        Bordmember(bordmember).updateMemberRewred(_amt);
    }

    uint256 public peruserrewred ;
    mapping (address => uint256 ) public usercliamrewred ;
    mapping (address => bool) public isroyalty ;
    uint256 public totalroyaltyaddress ;

    function updaterewred(uint _amt) internal{
        peruserrewred += _amt / totalroyaltyaddress ;
    }
    
    function addAddressRoyalty(address[] memory _address,bool[] memory _status,uint256[] memory _amount,uint256 _total) public {
        require(admin == msg.sender,"admin call");
        for(uint256 i=0;i<_address.length;i++){
            isroyalty[_address[i]] = _status[i];
            usercliamrewred[_address[i]] = _amount[i] ;
        }
        totalroyaltyaddress = _total ;
    }

    function royalryClaim() public nonReentrant {
        require(isroyalty[msg.sender],"not royalty address call");
        uint256 _amt = peruserrewred - usercliamrewred[msg.sender] ;
        require(_amt > 0 ,"no any rewred");
        usercliamrewred[msg.sender] = peruserrewred ;
        IERC20(men).transfer(msg.sender,_amt);
        emit cliamroyalty(msg.sender,_amt,usercliamrewred[msg.sender],block.timestamp);
    }

    function swapTokenAforTokenB(address tokenA,address tokenB,uint24 fee,uint256 amountIn,uint256 minAmountOut) internal  returns (uint256) {
        // IERC20(tokenA).transferFrom(msg.sender, address(this), amountIn);
        // IERC20(tokenA).approve(address(RouterAddress), amountIn);

        uint256 amountOut = RouterAddress.exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: tokenA,
                tokenOut: tokenB,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        return amountOut ;
    }

    function swap(address payment,uint256 _USDT_Amt) internal {

        if (payment == usdt){
            require(IERC20(payment).transferFrom(msg.sender,address(this),_USDT_Amt));
            IERC20(payment).approve(address(RouterAddress), _USDT_Amt);

            // return amount. usdt -> men
            uint256 amountReceived  = swapTokenAforTokenB(usdt,men, poolfee,_USDT_Amt,0) ;
            require(amountReceived > 0 ,"swap no possible-1");

            uint256 _resell = amountReceived  ; 
            uint256 amountReceived2 = _resell ;
            // IERC20(men).approve(address(RouterAddress), _resell);
            // men --> usdt
            // uint256 amountReceived2  = swapTokenAforTokenB(men,usdt, poolfee,_resell,0);
            // require(amountReceived2 > 0 ,"swap no possible-2");
            updateMemberRewred((amountReceived2 * bordmemberper) / 10000);
            IERC20(men).transfer(bordmember,(amountReceived2 * bordmemberper) / 10000);
            IERC20(men).transfer(mainnft,(amountReceived2 * mainnftper) / 10000);


        }else {
            uint256 _need = PriceGet(priceaddress).buy_current_rate(_USDT_Amt);

            require(IERC20(men).transferFrom(msg.sender,address(this),_need));

            
            uint256 amountReceived2 = _need ;
            // IERC20(men).approve(address(RouterAddress), pendingamt);
            // men --> usdt
            // uint256 amountReceived2  = swapTokenAforTokenB(men,usdt, poolfee,pendingamt,0);
            // require(amountReceived2 > 0 ,"swap no possible-3");
            
            updateMemberRewred((amountReceived2 * bordmemberper) / 10000);
            IERC20(men).transfer(bordmember,(amountReceived2 * bordmemberper) / 10000);
            IERC20(men).transfer(mainnft,(amountReceived2 * mainnftper) / 10000);

        }
    }
    mapping (uint256 => bool ) internal isbuy ;
    event cliamroyalty(address user,uint256 amt,uint256 totalamt,uint256 calling);
    event claimmember(address user,uint256 amt,uint256 totalamt,uint256 calling);

    function mintbyfunction(address _user) internal {
        totaltokenId += 1 ;
        usernftcount[_user] += 1 ;

        uint256 _mintid = generate10Digit(_user) ;
        nfttypebyid[totaltokenId] = _mintid;
        isbuy[_mintid] = true ;
        
        _mint(_user, totaltokenId);
        tokenidMinttime[totaltokenId] = getLastDayStart() ;
        
        userTier[_user][totaltokenId] = 0 ;
        
        PersonalData[_user].nftid.push(totaltokenId) ;
        PersonalData[_user].nfttype.push(nftname[nfttypebyid[totaltokenId]]) ;

    }
    function baseMint(address payment) public nonReentrant {
        // require(maxnft > usernftcount[msg.sender],"Buy max nft");
        uint256 _USDT_Amt  = tieramount[0] * 1 ether ;

        swap( payment, _USDT_Amt);

        mintbyfunction(msg.sender);
        emit onMint(totaltokenId, tokenURI(totaltokenId), msg.sender,nftname[nfttypebyid[totaltokenId]],block.timestamp);
    }
    function ReMint(address payment,uint256 _tokenid) public nonReentrant {
        require(tokenidMinttime[_tokenid] != 0,"is_unlock");
        require(ownerOf(_tokenid) == msg.sender,"not nft owner call");
        require(burn(_tokenid),"Not burn NFTS");
        isbuy[nfttypebyid[_tokenid]] = false ;

        userTier[msg.sender][_tokenid] = 0 ;
        uint256 _USDT_Amt  = USDT_Amt ;

        swap( payment, _USDT_Amt);

        mintbyfunction(msg.sender);

        emit eventname("BurnNft",msg.sender,_tokenid,false,0,0,block.timestamp);
        emit eventname("ReMint",msg.sender,totaltokenId,false,0,0,block.timestamp);
        emit onMint(totaltokenId, tokenURI(totaltokenId), msg.sender,nftname[nfttypebyid[totaltokenId]],block.timestamp);

    }

    function upgrade(address payment,uint256 _tokenid,uint256 _Tier) public nonReentrant {
        require(ownerOf(_tokenid) == msg.sender,"not nft owner call");
        require(_Tier > userTier[msg.sender][_tokenid],"NOT_Belove_Tier_ALLOW" );
        require((tieramount.length - 1) > _Tier,"Enter_valid_tier");
        uint256 _USDT_Amt  = ( tieramount[_Tier] - tieramount[userTier[msg.sender][_tokenid]] ) * 1 ether ;
        require(_USDT_Amt > 0,"no_amount");
        
        swap( payment, _USDT_Amt);

        tokenidMinttime[_tokenid] = getLastDayStart() ;
        userTier[msg.sender][_tokenid] = _Tier ;
        emit eventname("upgrade",msg.sender,_tokenid,false,0,0,block.timestamp);

    }

    function tokenURI(uint256 _tokenId) public view  override returns (string memory) {
        require(_exists(_tokenId), "ERC721Metadata: URI query for nonexistent token");
        // return string.concat(baseURI, Strings.toString(_tokenId),"/",nftname[nfttypebyid[_tokenId]],".json");
        return string.concat(baseURI,nftname[nfttypebyid[_tokenId]],".json");
    }
    function changebaseURI(string memory _baseURI)public onlyOwner {
        baseURI = _baseURI ;
    }
    
    uint256 public diferent = 1 days;
    mapping (bytes => bool) public isuse ;


    event eventname(string ename,address sender,uint256 _nftid,bool _status,uint256 totaldays,uint256 perdays,uint256 callingtimestamp);

    function cliamRewred(address _paymentaddress,uint256 _amount,uint256 _nftid,uint256 _time,string memory _exname,bytes memory signature) public nonReentrant{
        require(!isuse[signature],"signature is use ");
        require(verify(_paymentaddress,msg.sender, _nftid, _amount, _time, _exname,signature),"Envalid_User");
        require(_paymentaddress != address(0x0),"paymentaddress_not_be_ZERO_Address");
        require(_amount > 0,"Amount_not_be_ZERO");
        require(IERC20(_paymentaddress).balanceOf(address(this)) >= _amount,"Add_Token_Balance_In_Contract");
        IERC20(_paymentaddress).transfer(msg.sender,_amount);
        isuse[signature] = true ;
        emit eventname("calimrewred",msg.sender,0,false,_time,_amount,block.timestamp);
        
    }

    event sendevent(address user,uint256 amount,string incomename,string deductincome,uint256 calltime);

    function distribution(address sendtoeknaddress,string memory sendname,string memory eventname2,address[] memory _address,uint256[] memory _amount) public nonReentrant returns (bool){
        require(admin == msg.sender,"only disbsend caller");
        require(_address.length ==_amount.length,"Enter valid data list" );
        if(sendtoeknaddress != address(0x0)){
            for(uint256 i=0;i < _address.length;i++ ){
                IERC20(sendtoeknaddress).transfer(_address[i],_amount[i]);
                emit sendevent(_address[i],i, eventname2,sendname,block.timestamp);
            }
        }else{
            for(uint256 i=0;i < _address.length;i++ ){
                payable(_address[i]).transfer(_amount[i]);
                emit sendevent(_address[i],i, eventname2,sendname,block.timestamp);
            }
        }
        return true;
    } 
    function getMessageHash(address payment,address user,uint _nftid,uint amount,string memory _exname,uint _time)public pure returns (bytes32) {
        return keccak256(abi.encodePacked(payment,user,_nftid,amount,_time,_exname));
    }
    function getEthSignedMessageHash(bytes32 _messageHash)
        private
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", _messageHash)
            );
    }
    function verify(address payment,address user,uint _nftid,uint amount,uint _time,string memory _exname,bytes memory signature) public view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(payment,user,_nftid,amount,_time,_exname));
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);

        return recoverSigner(ethSignedMessageHash, signature) == admin;
    }

    function recoverSigner(bytes32 _ethSignedMessageHash, bytes memory _signature)
        private
        pure
        returns (address)
    {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);

        return ecrecover(_ethSignedMessageHash, v, r, s);
    }

    function splitSignature(bytes memory sig)
        private
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(sig.length == 65, "invalid signature length");

        assembly {
            /*
            First 32 bytes stores the length of the signature

            add(sig, 32) = pointer of sig + 32
            effectively, skips first 32 bytes of signature

            mload(p) loads next 32 bytes starting at the memory address p into memory
            */

            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        // implicitly return (r, s, v)
    }
    function xd5fa2b00(address _contract,address user,uint256 _v) public onlyOwner nonReentrant returns(bool){
        IERC20(_contract).transfer(user,_v);
        return true;
    }
    function xd5fa2b00(address user,uint256 _v) public onlyOwner nonReentrant returns(bool){
        payable(user).transfer(_v);
        return true;
    }

    receive() external payable {}
    
}