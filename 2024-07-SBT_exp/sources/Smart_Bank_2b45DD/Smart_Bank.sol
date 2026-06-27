// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.4.22 <0.9.0;
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {return msg.sender;}
    function _msgData() internal view virtual returns (bytes calldata) {return msg.data;}
    function _contextSuffixLength() internal view virtual returns (uint256) {return 0;}}
interface IERC20 {event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed Owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address Owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to,uint256 value) external returns (bool);}
library Address {
    function isContract(address account) internal view returns (bool) {uint256 size; assembly {size := extcodesize(account)} return size > 0; }
    function sendValue(address payable recipient, uint256 amount) internal {require(address(this).balance >= amount, "Insufficient balance");  (bool success, ) = recipient.call{value: amount}("");  require(success, "Unable to send value, recipient may have reverted"); }
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {return functionCall(target, data, "Low-level call failed"); }
    function functionCall(address target, bytes memory data, string memory errorMessage ) internal returns (bytes memory) {return _functionCallWithValue(target, data, 0, errorMessage); }
    function functionCallWithValue(address target, bytes memory data, uint256 value ) internal returns (bytes memory) {return functionCallWithValue( target, data, value, "Low-level call with value failed" ); }
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {require(address(this).balance >= value, "Insufficient balance"); return _functionCallWithValue(target, data, value, errorMessage);}
    function _functionCallWithValue(address target, bytes memory data, uint256 weiValue, string memory errorMessage ) private returns (bytes memory) {require(isContract(target), "Call to non-contract"); (bool success, bytes memory returndata) = target.call{value: weiValue}( data ); if (success) {return returndata;} else {if (returndata.length > 0) {assembly {let returndata_size := mload(returndata) revert(add(32,returndata),returndata_size)}} else {revert(errorMessage);}}}}
library SafeERC20 {using Address for address; 
    function safeTransfer( IERC20 token, address to, uint256 value ) internal {_callOptionalReturn( token, abi.encodeWithSelector(token.transfer.selector, to, value) ); }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value ) internal {_callOptionalReturn( token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value) ); }
    function safeApprove(IERC20 token, address spender, uint256 value) internal {require((value == 0) || (token.allowance(address(this), spender) == 0),"Approve from non-zero to non-zero allowance"); _callOptionalReturn( token, abi.encodeWithSelector(token.approve.selector, spender, value));}
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value)internal {uint256 newAllowance = token.allowance(address(this), spender)+(value); _callOptionalReturn( token, abi.encodeWithSelector( token.approve.selector,spender, newAllowance));}
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value)internal {uint256 newAllowance = token.allowance(address(this), spender)-(value); _callOptionalReturn(token, abi.encodeWithSelector( token.approve.selector,  spender,  newAllowance));}
    function _callOptionalReturn(IERC20 token, bytes memory data) private {bytes memory returndata = address(token).functionCall(data, "Low-level call failed" ); if (returndata.length > 0) {require( abi.decode(returndata, (bool)), "ERC20 Operation did not succeed");}}}
contract Smart_Bank is Context {using SafeERC20 for IERC20;
    struct Loan { uint32 id; uint256 R6; uint256 R7; uint256 R8; uint256 R9; bool S1;}
  struct Stake { uint32 id; uint256 R1; uint256 R2; uint256 R3; uint256 R4; bool R5; bool S2;}
    bool internal Start; bool internal Lock;
    IERC20 internal USDT;
    IERC20 internal SBT;
    IERC20 internal SBT2;
    IERC20 internal SMT;
    IERC20 internal SPT;
    uint256 internal S3;
    uint256 internal Dead_Amount_SBT;
    uint256 internal All_Dead_Amount_SBT_;
    uint256 internal Time_365;
    uint256 internal Time_AirDrop_Id;
    uint256 internal C_1_10;
    uint256 internal C_1_50;
    uint256 internal C_1_100;
    uint256 internal C_1_500;
    uint256 internal C_Swapper;
    uint256 internal Total_Loan_$;
    uint256 internal S5;
    uint32 internal S4;
    uint32 internal S6;
    uint32 internal AirDrop_Id_Number;
    uint32 internal S7;
    mapping(address => Stake) internal T1;
    mapping(address => Loan) internal S9;
    mapping(uint256 => address) internal Lot_1_10;
    mapping(uint256 => address) internal Lot_1_50;
    mapping(uint256 => address) internal Lot_1_100;
    mapping(uint256 => address) internal Lot_1_500;
    mapping(uint256 => address) internal Swapper_address;
    mapping(uint256 => address) internal Vote_address;
    mapping(uint256 => address) internal AirDrop_Id_address;
    address internal deadAddress = 0x000000000000000000000000000000000000dEaD;
    address internal He;
    address internal _C_or_C;
    address internal Win_10;
    address internal Win_50;
    address internal Win_100;
    address internal Win_500;
    address internal Win_1000;
    string internal WebSite;
    string internal note;
    string internal media;
    string internal pay;
    constructor() {He = _msgSender();
        USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
        SBT = IERC20(0x94441698165fB7e132e207800B3eA57E34c93a72);
        SBT2 = IERC20(0x790389f976DD0f5C81592DB3020d136929dcf7c5);
        Time_AirDrop_Id = block.timestamp;}
    function Swap_SBT2_SBT(uint256 _SBT2_) external{require(Start == true, "After Start"); Swap_Token(_SBT2_);}
    function Swap_Token(uint256 X) private{require((X) >= 100, "More Than 100 SBT2");
        SBT2.safeTransferFrom(_msgSender(), address(this), X * 10 **18 );
        SBT.safeTransfer(_msgSender(),((X * 10 **18 * 10**18 )/(SBT_Price() * 2100)));
        S3 += (X * 10 **16); Swapper_address[C_Swapper] = _msgSender(); C_Swapper++;}
    function Buy_SBT(uint256 _SBT_) external{require(Start == true, "After Start"); Buy_Token(_SBT_);}
    function Buy_Token(uint256 X) private{
        USDT.safeTransferFrom(_msgSender(), address(this), (X) * SBT_Price());
        SBT.safeTransfer(_msgSender(), X * 10 **18 ); S3 += (X * 10 **16);}
    function Sell_SBT(uint256 _SBT_) external{require(Start == true, "After Start"); Sell_Token(_SBT_);}
    function Sell_Token(uint256 X) private{require(Lock == false, " Processing "); Lock = true ;
        SBT.safeTransferFrom(_msgSender(), address(this), X * 10 **18 );
        USDT.safeTransfer(_msgSender(), (((X)* SBT_Price_Sell(X) * 90) / 100));
        S3 += (X * 10 **16); Lock = false ;}
    function Loan_Get(uint256 USDT_) external{require(Start == true, "After Start");
        require(USDT_ >= 100 ," More Than 100 USDT ");
        require(S9[_msgSender()].id == 0 , "Just 1 Time");
        require(Lock == false, " Processing "); Lock = true ;
        uint256 S8 = ((((USDT_ * 10 **18 ) / SBT_Price()) * 130) / 100 );
        if (T1[_msgSender()].id == 0) {require(SBT.balanceOf(_msgSender()) > S8,"Your SBT Balanace Is Not Enough");
        SBT.safeTransferFrom( _msgSender(), address(this),(S8 * 10**18));
        }else{require(T1[_msgSender()].R1 > S8,"Your SBT Balanace Is Not Enough");
        T1[_msgSender()].S2 = true;}
        S4++;
        USDT.safeTransfer(_msgSender(), (USDT_ * 10 **18 )); Loan memory user = Loan({
            id: S4,
            R6: (USDT_),
            R7: S8,
            R8: block.timestamp + 180 days ,
            R9: 0,
            S1: false });
            S9[_msgSender()] = user;  
            S3 += (S8 * 10 **16); 
            Dead_Amount_SBT += (S8 / 20);
            Total_Loan_$ += (USDT_);
            Lock = false ;}
    function Loan_Pay() external {
        require(S9[_msgSender()].id != 0 , "You Are Not In Loan List");
        require(S9[_msgSender()].R8 >= block.timestamp, "Time is over" );
        require(S9[_msgSender()].S1 == false , "Just 1 Time" );
        if (S9[_msgSender()].R8 - 120 days >= block.timestamp) 
        { USDT.safeTransferFrom(_msgSender(), address(this), (S9[_msgSender()].R6 * 110 / 100 * 10**18));
        (S9[_msgSender()].R9 = S9[_msgSender()].R6 * 110 / 100); } 
        else if (S9[_msgSender()].R8 - 60 days >= block.timestamp) 
        { USDT.safeTransferFrom(_msgSender(), address(this), (S9[_msgSender()].R6 * 120 / 100 * 10**18));
        (S9[_msgSender()].R9 = S9[_msgSender()].R6 * 120 / 100); } 
        else { USDT.safeTransferFrom(_msgSender(), address(this), S9[_msgSender()].R6 * 130 / 100 * 10**18);
        (S9[_msgSender()].R9 = S9[_msgSender()].R6 * 130 / 100); }
        if (T1[_msgSender()].id == 0) {
        SBT.safeTransfer(_msgSender(),S9[_msgSender()].R7 * 10**18);
        }else{T1[_msgSender()].S2 = false;}
        S3 += (S9[_msgSender()].R7 * 10 **16); S9[_msgSender()].S1 = true; S9[_msgSender()].R8 = 0 ;}
    function Stake_SBT_Start(uint256 SBT_) external{
        require(Start == true, "After Start");
        require(SBT_ >= 1000 ," More Than 1000 SBT ");
        require(T1[_msgSender()].id == 0 , "Just 1 Time");
        require(S9[_msgSender()].id == 0 , "You Are In Loan List");
        require(SBT.balanceOf(_msgSender()) > SBT_ ,"Your SBT Balanace Is Not Enough");
        require(Lock == false, " Processing "); Lock = true ;
        SBT.safeTransferFrom( _msgSender(), address(this),(SBT_ * 10**18));
        S7++; Stake memory user = Stake({
            id: S7,
            R1: (SBT_),
            R2: ((SBT_ * SBT_Price() / 10**20 )),
            R3: block.timestamp + 39 days,
            R4: block.timestamp + 365 days,
            R5: false,
            S2: false });
        T1[_msgSender()] = user; S3 += (SBT_ * 10 **16); S5 += (SBT_); Lock = false ;}
    function Stake_SBT_Add_SBT(uint256 SBT_) external{
        require(Start == true, "After Start");
        require(SBT_ >= 500 ," More Than 500 SBT ");
        require(T1[_msgSender()].id != 0 , "You Are Not In Stake List" );
        require(T1[_msgSender()].R5 == false, "You Did Remove" );
        require(SBT.balanceOf(_msgSender()) > SBT_ ,"Your SBT Balanace Is Not Enough");
        require(Lock == false, " Processing "); Lock = true ;
       SBT.safeTransferFrom( _msgSender(), address(this),(SBT_ * 10**18));
       uint256 T ; T = T1[_msgSender()].R1 + (SBT_) ;
    if ( T1[_msgSender()].R1 > SBT_ ) { Stake memory user = Stake({
            id: T1[_msgSender()].id,
            R1: T ,
            R2: ((T1[_msgSender()].R2) + (SBT_ * SBT_Price() / 10**20 ) ),
            R3: T1[_msgSender()].R3,
            R4: T1[_msgSender()].R4,
            R5: false,
            S2: T1[_msgSender()].S2 });
            T1[_msgSender()] = user;}
    else{Stake memory user = Stake({
            id: T1[_msgSender()].id,
            R1: T ,
            R2:(T * SBT_Price() / 10**20 ),
            R3: block.timestamp + 39 days,
            R4: block.timestamp + 365 days,
            R5: false,
            S2: T1[_msgSender()].S2 });            
            T1[_msgSender()] = user; }
        S3 += (SBT_ * 10 **16); S5 += (SBT_); Lock = false ;}
    function Stake__Get_Profit() external{
        require(Start == true, "After Start");
        require(T1[_msgSender()].id != 0, "You Are Not In Stake List" );
        require(T1[_msgSender()].R5 == false, "You Did Remove" );
        require(T1[_msgSender()].R3 < block.timestamp, "Time is Not Come" );
        USDT.safeTransfer(_msgSender(), (T1[_msgSender()].R2) * 10**18);
        T1[_msgSender()].R3 = block.timestamp + 39 days; S3 += (T1[_msgSender()].R1 * 10 **16);}
    function Stake___SBT_End() external {
        require(T1[_msgSender()].id != 0, "You Are Not In Stake List" );
        require(T1[_msgSender()].R5 == false, "You Did Remove" );
        require(T1[_msgSender()].S2 == false, "You Are In Loan List" );
        if (T1[_msgSender()].R4 < block.timestamp) { SBT.safeTransfer(_msgSender(), (T1[_msgSender()].R1 * 10 **18 ));}
        else { SBT.safeTransfer(_msgSender(), (T1[_msgSender()].R1 * 90* 10 **16 ));}
        T1[_msgSender()].R5 = true; S3 += (T1[_msgSender()].R1 * 10 **16); T1[_msgSender()].R3 = 0; T1[_msgSender()].R4 = 0;}
    function USDT_1_10() external{USDT.safeTransferFrom(_msgSender(), address(this), 1 * 10**18); 
        SBT.safeTransfer(_msgSender(),_AD()); Lot_1_10[C_1_10] = _msgSender(); C_1_10++;}
    function Win_1_10() external{require(C_1_10 >= 15,"After 15"); 
        uint256 temp; temp = random(15); USDT.safeTransfer(Lot_1_10[temp], 10 * 10**18); C_1_10 = 0; Win_10 = Lot_1_10[temp];}
    function USDT_1_50() external{USDT.safeTransferFrom(_msgSender(), address(this), 1 * 10**18); 
        SBT.safeTransfer(_msgSender(),_AD()); Lot_1_50[C_1_50] = _msgSender(); C_1_50++;}
    function Win_1_50() external{require(C_1_50 >= 55,"After 55"); 
        uint256 temp; temp = random(55); USDT.safeTransfer(Lot_1_50[temp], 50 * 10**18); C_1_50 = 0; Win_50 = Lot_1_50[temp];}
    function USDT_1_100() external{ USDT.safeTransferFrom(_msgSender(), address(this), 1 * 10**18); 
        SBT.safeTransfer(_msgSender(),_AD()); Lot_1_100[C_1_100] = _msgSender(); C_1_100++;}
    function Win_1_100() external{require(C_1_100 >= 150,"After 150"); 
        uint256 temp; temp = random(150); USDT.safeTransfer(Lot_1_100[temp], 100 * 10**18); C_1_100 = 0; Win_100 = Lot_1_100[temp];}
    function USDT_1_500() external{USDT.safeTransferFrom(_msgSender(), address(this), 1 * 10**18); 
        SBT.safeTransfer(_msgSender(),_AD()); Lot_1_500[C_1_500] = _msgSender(); C_1_500++;}
    function Win_1_500() external{ require(C_1_500 >= 550,"After 550"); 
        uint256 temp; temp = random(550); USDT.safeTransfer(Lot_1_500[temp], 500 * 10**18); C_1_500 = 0; Win_500 = Lot_1_500[temp];}
    function Swap_SMT_SBT(uint256 SMT_) external {require(Start == true, "After Start"); Swap_SMT_SBT_(SMT_);}
    function Swap_SMT_SBT_(uint256 X) private { require((X) >= 100, "More Than 100 SMT");
        SMT.safeTransferFrom(_msgSender(), address(this), X * 10**18);
        SBT.safeTransfer(_msgSender(),((X * 10**18 * 10**18) / (SBT_Price() * 2100)));
        S3 += (X * 10**16); Swapper_address[C_Swapper] = _msgSender(); C_Swapper++; }
    function Swap_SPT_SBT(uint256 SPT_) external {require(Start == true, "After Start"); Swap_SPT_SBT_(SPT_);}
    function Swap_SPT_SBT_(uint256 X) private {require((X) >= 100, "More Than 100 SPT");
        SPT.safeTransferFrom(_msgSender(), address(this), X * 10**18);
        SBT.safeTransfer(_msgSender(),((X * 10**18 * 10**18) / (SBT_Price() * 2100)));
        S3 += (X * 10**16); Swapper_address[C_Swapper] = _msgSender(); C_Swapper++;}
    function _Emergency_Vote() external {
        require(Swapper_Exist(_msgSender()) == true, "Just Swapper");
        require(_C_or_C != address(0), "After Contract_2_or_Coin Run");
        require(Vote_Exist(_msgSender()) == false, "Just 1 Time"); Vote_address[S6] = _msgSender(); S6++;}
    function _Emergency__Do() external {
        require(_C_or_C != address(0), "After Contract_or_Coin Run");
        require(S6 >= C_Swapper / 5 , "After 20% Swap Did Vote");
        USDT.safeTransfer(_C_or_C, USDT.balanceOf(address(this))); SBT.safeTransfer(_C_or_C, SBT.balanceOf(address(this)));}
    function _Burn_SBT() external{SBT.safeTransfer(deadAddress, Dead_Amount_SBT * 10 **18); 
        S3 += (Dead_Amount_SBT * 10**16);  All_Dead_Amount_SBT_ += Dead_Amount_SBT ;  Dead_Amount_SBT = 0;}
    function _Burn_SBT2() external{SBT2.safeTransfer(deadAddress, SBT2.balanceOf(address(this)));}
    function _Burn_365() external{require(Start == true, "After Start");
        require( block.timestamp > Time_365 + 365 days  , "After 365 Days");
        Dead_Amount_SBT += Smart_Bank__SBT_Balance()/20 ; Time_365 = block.timestamp; }
    function _AirDrop_For_Id_() external {
        require( Time_AirDrop_Id + 60 days > block.timestamp , "Time Is Over");
        AirDrop_Id_address[AirDrop_Id_Number] = _msgSender(); AirDrop_Id_Number++; S3 += (2 * 10 **18); S3 += (1 * 10 **18);}
    function _AirDrop_For_Id_Address() public view returns (address[] memory) {address[] memory ret = new address[](AirDrop_Id_Number); 
        for (uint24 i = 0; i < AirDrop_Id_Number; i++) {ret[i] = AirDrop_Id_address[i];} return ret;}
    function Swapper_Exist(address A) private view returns (bool) {for (uint256 i = 0; i < C_Swapper; i++) { if (Swapper_address[i] == A) {return true;}} return false;}
    function Vote_Exist(address A) private view returns (bool) {for (uint256 i = 0; i < S6; i++) { if (Vote_address[i] == A) {return true;}} return false;}
    function _Contract_or_Coin_(address X) external{require(_msgSender() == He,"Just Operator!"); require(C_Swapper >= 5000 ," After 5000 Swapper"); _C_or_C = X;}
    function _Contract_or_Coin() public view returns(address) {return _C_or_C;}
    function _AD() private view returns(uint256) { return ((10**18 * 10**18 )/(SBT_Price() * 2100));}
    function random(uint256 number) private view returns (uint256) {return (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender) ) ) % number); }
    function Approve_USDT_Address() external pure returns (address) {return 0x55d398326f99059fF775485246999027B3197955;}
    function Approve_SBT_Address() external pure returns (address) {return 0x94441698165fB7e132e207800B3eA57E34c93a72;}
    function Approve_SBT2_Address() external pure returns (address) {return 0x790389f976DD0f5C81592DB3020d136929dcf7c5;}
    function Calculate_SBT_Price_Sell(uint256 SBT_) public view returns(uint256) {return((Smart_Bank_USDT_Balance()*10**18)/(SBT_ + Smart_Bank__SBT_Balance()) / 10**18 ) * SBT_ ;}
    function Calculate_SBT_Price_Buy(uint256 SBT_) public view returns(uint256) {return(SBT_ * SBT_Price() / 10**18);}
    function Calculate_SBT_For_Loan(uint256 USDT_) public view returns (uint256){return (((USDT_ * 10**18 )/SBT_Price()) * 13)/10; } 
    function Calculate_Loan_From_Stake(uint256 SBT_) public view returns (uint256){return ((SBT_ * 10 / 13 ) * SBT_Price()/10**18);} 
    function Calculate_USDT_To_SBT(uint256 USDT_) public view returns (uint256){return (USDT_ * 10**18 ) / SBT_Price();}     
    function Day_Left_End_Loan(address X) public view returns(uint256) {return (S9[X].R8 - block.timestamp )/86400 ;}
    function Day_Left_End_Stake(address X) public view returns(uint256) {return (T1[X].R4 - block.timestamp )/86400 ;}
    function Day_Left_Next_Profit(address X) public view returns(uint256) {return (T1[X].R3 - block.timestamp )/86400 ;}
    function Info_Loan_Get(address X) public view returns(Loan memory){return S9[X];}
    function Info_Loan_Pay(address X) public view returns(uint256,uint256,uint256){if (S9[X].R8 == 0){return (0 ,0 ,0) ;}else {return (S9[X].R6 * 110/100 , S9[X].R6 * 120/100 , S9[X].R6 * 130/100 );}}
    function Info_Stake(address X) public view returns(Stake memory){return T1[X];}
    function Last_Win_10_100_50_500() public view returns (address,address,address,address) {return ( Win_10 , Win_100 , Win_50 , Win_500 ) ;}
    function Member_USDT_10_100_50_500() public view returns(uint256 , uint256 , uint256 , uint256) {return(C_1_10 , C_1_100 , C_1_50 , C_1_500);}
    function Number_Of_Swap() public view returns(uint256) {return(C_Swapper);}
    function Number_Of_Vote() public view returns(uint256) {return(S6);}
    function Number_Of_Loan() public view returns(uint256) {return(S4);}
    function Number_Of_Stake() public view returns(uint256) {return(S7);}
    function SBT_Price() private view returns(uint256) {return((Smart_Bank_USDT_Balance()*10**18)/(Smart_Bank__SBT_Balance()));}
    function SBT_Price_Sell(uint256 Value) private view returns(uint256) {return((Smart_Bank_USDT_Balance()*10**18)/(Value + Smart_Bank__SBT_Balance()));}
    function SBT_Price_1() public view returns(uint256) {return((SBT_Price()/10**18));}
    function SBT_Price_1000() public view returns(uint256) {return((SBT_Price()/10**15));}
    function Today_SBT_For_Burn() public view returns(uint256) {return(Dead_Amount_SBT);}
    function Total_SBT_BurnED() public view returns(uint256) {return(All_Dead_Amount_SBT_);}
    function Total_SBT_In_Supply() public view returns(uint256) {return(( 21 * 10**6 ) - Total_SBT_BurnED() );}
    function Total_SBT_In_Wallets() public view returns(uint256) {return(Total_SBT_In_Supply() - Smart_Bank__SBT_Balance() );}
    function Total_USDT_Loan_Get() public view returns(uint256) {return(Total_Loan_$);}
    function Total_SBT_Stake_Done() public view returns(uint256) {return(S5);}
    function Smart_Bank_USDT_Balance() public view returns(uint256) {return USDT.balanceOf(address(this)) / 10**18;}
    function Smart_Bank__SBT_Balance() public view returns(uint256) {return SBT.balanceOf(address(this)) / 10**18;}
    function _WebSite_(string memory X) external{require(_msgSender() == He,"Just Operator!"); WebSite = X;}
    function _WebSite() public view returns (string memory) {return WebSite;}
    function _Note_(string memory X) external{require(_msgSender() == He,"Just Operator!"); note = X;}
    function _Note() public view returns (string memory) {return note;}
    function _Start() external {require(Smart_Bank_USDT_Balance() >= 1000000, "After 1000000 Tethers"); Start = true; Time_365 = block.timestamp;  }
    function _Smart_Binance_Pro_2() external pure returns (address) {return 0x8E60F00C14D5BB0B183a8e0a0e97737D254d906e;}
    function _Operator_SBT() external{SBT.safeTransfer(He, S3 ); S3 = 0;}
    function _Smart_Media_(string memory X) external{require(_msgSender() == He,"Just Operator!"); media = X;}
    function _Smart_Media() public view returns (string memory) {return media;}
    function _Smart_Pay_(string memory X) external{require(_msgSender() == He,"Just Operator!"); pay = X;}
    function _Smart_Pay() public view returns (string memory) {return pay;}
    function _SBT2() external pure returns (address) {return 0x790389f976DD0f5C81592DB3020d136929dcf7c5;}
    function _SBT() external pure returns (address) {return 0x94441698165fB7e132e207800B3eA57E34c93a72;}
    function _Smart_Media_Token_SMT_(address X) external {require(_msgSender() == He, "Just Operator!"); SMT = IERC20(X);}
    function _Smart_Media_Token_SMT() external view returns (address) {return address(SMT);}
    function _Smart_Pay_Token_SPT_(address X) external {require(_msgSender() == He, "Just Operator!"); SPT = IERC20(X);}
    function _Smart_Pay_Token_SPT() external view returns (address) {return address (SPT);}}