// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


interface IBEP20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}
library Counters {
    struct Counter {
        uint256 _value; 
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

    function reset(Counter storage counter) internal {
        counter._value = 0;
    }
}

contract INcufi {
    address public owner;
    uint public Firstlevel;
    uint public Secondlevel;
    uint public HeadPercent;
  
    uint public Price;
    uint public setdecimal;
    uint totaldepsoit;
    uint ownerwithdral;
    uint totalwithdral;
    uint256 public totalParticipants;
    uint public Limit;

    using Counters for Counters.Counter;
    Counters.Counter private SId;
    // Counters.Counter private PId;
    Counters.Counter private  WId;
    Counters.Counter private  WeId;
    IBEP20 public contractToken;
    IBEP20 public NativeContractToken;
    IBEP20 public CommissionContractToken;

     struct User{
        address myAddress;
        address sponsore;
        address secondSsponsore;
        address [] downline;
        address [] secondLeveldownline;
        uint time;
        bool exist;
     }
     struct order{
        uint id;
        uint amount;
        uint apy;
        uint period;
        uint startdate;
        uint enddate;
        bool complet;
        address USer;
        uint withdraltime;
        uint PRice;
        uint decimal;
       // uint earningwithdralusd;
        uint earningwithdralAkita;
     }
     struct Withdraw{
        uint id;
        uint orderid;
        address USer;
        uint amount;
        uint withdraltime;
     }
     struct WithdrawEarning{
        uint id;
        uint orderid;
        address USer;
      //  uint usdAmount;
        uint akitaAmount;
        uint withdraltime;
     }

     mapping(address => User) public user;
      mapping (uint => order) public OrdereMap;
      mapping (uint => uint) public ApyLock;
       mapping (uint => Withdraw) public WithdrawMap;
       mapping (uint => WithdrawEarning) public WithdrawEarningMap;
       mapping (uint => address) public countryhead;
       mapping (address => uint) public commisionAmount;
       mapping (address => uint) public swapAmount;
    
     constructor(address _owner, uint price, 
     address usdt , address akita, uint _setdecimal,uint first, uint sencod,uint headPerctange, address commision,uint limit){
        owner = _owner;
        Price = price;
        Firstlevel = first;
        Secondlevel = sencod;
        HeadPercent = headPerctange;
        contractToken = IBEP20(usdt);
        NativeContractToken = IBEP20(akita);
        setdecimal = _setdecimal;
        user[_owner] = User(_owner,_owner,_owner,new address[](0),new address[](0),block.timestamp,true);
        CommissionContractToken = IBEP20(commision);
        Limit = limit;
        totalParticipants++;

     }

     function changeOwner(address _owner)public{
        require (msg.sender == owner,"Not an Owner");
        owner = _owner;
        user[_owner] = User(_owner,_owner,_owner,new address[](0),new address[](0),block.timestamp,true);
        totalParticipants++;
     }
      function setPrice(uint price) public{
      require (msg.sender == owner,"Not an Owner");
      Price = price;
     }
     function changelimit(uint limit) public{
      require (msg.sender == owner,"Not an Owner");
       Limit = limit;
     }
     function setcountryHead(uint countryid, address _countryHead) public{
     require (msg.sender == owner,"Not an Owner");
     countryhead[countryid] = _countryHead;//referr to excel sheet
 }
     function setLockAPY(uint day, uint APY) public{
     require (msg.sender == owner,"Not an Owner");
     ApyLock[day] = APY;
 }
      function setPriceDecimal(uint Decimal) public{
      require (msg.sender == owner,"Not an Owner");
      setdecimal = Decimal;
     }
     function setfirstlevel(uint percange) public{
      require (msg.sender == owner,"Not an Owner");
      Firstlevel = percange;
     }
     function setsecondlevel(uint percange) public{
      require (msg.sender == owner,"Not an Owner");
      Secondlevel = percange;
     }
     function setHeadPercentage(uint percange) public{
      require (msg.sender == owner,"Not an Owner");
      HeadPercent = percange;
     }
      function changeAkitaAddrees (address newAkita) public{
      require (msg.sender == owner,"Not an Owner");
      NativeContractToken = IBEP20(newAkita);
     }
      function isRegistered(address participant) public view returns (bool) {
      return user[participant].sponsore != address(0);
     }
     function getTotalstacking() public view returns (uint) {
     require (msg.sender == owner,"Not an Owner");
     return totaldepsoit;
     }
     function getTotalwithdral() public view returns (uint) {
     require (msg.sender == owner,"Not an Owner");
     return totalwithdral;
     }
     function getTotalownerwithdral() public view returns (uint) {
     require (msg.sender == owner,"Not an Owner");
     return ownerwithdral;
     }
     
     function register(address referrer)  public {
        require(msg.sender != referrer && !isRegistered(msg.sender), "Invalid registration");
        require(isRegistered(referrer)==true,"Reffral not registred");
        address sencod = user[referrer].sponsore;
        user[msg.sender] = User(msg.sender,referrer,sencod, new address[](0), new address[](0),block.timestamp,true);
        user[referrer].downline.push(msg.sender);
        user[sencod].secondLeveldownline.push(msg.sender);
        totalParticipants++;
     }
     function STAKE (uint amout ,uint day,uint countryid) public {
       require( isRegistered(msg.sender) == true);
       contractToken.transferFrom(msg.sender, address(this), amout);
       uint APy = ApyLock[day];
       address head = countryhead[countryid];
       address sponser = user[msg.sender].sponsore;
       uint end = block.timestamp+(day*86400);
       address secondSponser = user[msg.sender].secondSsponsore;
       uint one = (amout*Firstlevel)/(100);
       uint two = (amout*Secondlevel)/(100);
       uint he = (amout*HeadPercent)/(100);
        CommissionContractToken.transfer(sponser,one);
        CommissionContractToken.transfer(secondSponser,two);
        CommissionContractToken.transfer(head,he);
       SId.increment();
       uint newID = SId.current();
       OrdereMap[newID] = order(newID,amout,APy,day,block.timestamp,end,false,msg.sender,0,Price,setdecimal,0);
       totaldepsoit+=amout;
       commisionAmount[sponser]+=one;
       commisionAmount[secondSponser]+=two;
       commisionAmount[head]+=he;
     }

     function Ownerwithdrwal(uint amount)public{
     require (msg.sender == owner,"Not an Owner");
     contractToken.transfer(owner,amount);
     ownerwithdral+=amount;
}
function withdral(uint id) public{
    require (OrdereMap[id].complet == false,"already complet");
    require (OrdereMap[id].USer== msg.sender,"not your order");
    require (OrdereMap[id].enddate< block.timestamp,"not your order");
     contractToken.transfer(msg.sender,OrdereMap[id].amount);
     OrdereMap[id].complet = true;
     OrdereMap[id].withdraltime = block.timestamp;
     WId.increment();
     uint newLockID = WId.current();
    WithdrawMap[newLockID]= Withdraw(newLockID,id,msg.sender,OrdereMap[id].amount, block.timestamp);
    totalwithdral+=OrdereMap[id].amount;
}
function listMyoID() public view returns (order [] memory){
        uint LockcountItem = SId.current();
        uint activeTradeCount =0;
        uint current =0;
        for (uint i=0; i< LockcountItem; i++){
            if(OrdereMap[i+1].USer == msg.sender){
                activeTradeCount +=1;
        }
    }
     order[] memory items1 = new order[](activeTradeCount);
      for (uint i=0; i< LockcountItem; i++){
             if(OrdereMap[i+1].USer == msg.sender){
                uint currentId = OrdereMap[i+1].id;
                order storage currentItem = OrdereMap[currentId];
                items1[current] = currentItem;
                current +=1;
             }
        }
        return items1;

}
function listMywID() public view returns (Withdraw [] memory){
        uint LockcountItem = WId.current();
        uint activeTradeCount =0;
        uint current =0;
        for (uint i=0; i< LockcountItem; i++){
            if(WithdrawMap[i+1].USer == msg.sender){
                activeTradeCount +=1;
        }
    }
     Withdraw[] memory items1 = new Withdraw[](activeTradeCount);
      for (uint i=0; i< LockcountItem; i++){
             if(WithdrawMap[i+1].USer == msg.sender){
                uint currentId = WithdrawMap[i+1].id;
                Withdraw storage currentItem = WithdrawMap[currentId];
                items1[current] = currentItem;
                current +=1;
             }
        }
        return items1;

}
function listorderActive() public view returns(uint) {
    uint LockcountItem = SId.current();
    uint active = 0;
    uint activeTradeCount = 0;
    for (uint i = 0; i < LockcountItem; i++) {
        if (OrdereMap[i + 1].USer == msg.sender && !OrdereMap[i + 1].complet) {
            activeTradeCount += 1;
            active++;
        }
    }

    return active;
}
    function earning (uint id) public view returns(uint){
     uint amt = OrdereMap[id].amount;
    // uint earninginusd;
     uint earninginakita;
     uint starttime = OrdereMap[id].startdate;
     uint withdraltime = OrdereMap[id].enddate;
     uint with1 = OrdereMap[id].withdraltime;
     uint APY = OrdereMap[id].apy;
   //  uint usdtear = OrdereMap[id].earningwithdralusd;
     uint akitaer = OrdereMap[id].earningwithdralAkita;
     uint p = OrdereMap[id].PRice;
     uint d = OrdereMap[id].decimal;
     if(with1 ==0){
     uint earningusd = (amt*(block.timestamp-starttime)*APY)/3153600000;
        //earninginusd = (earningusd -usdtear)/2;
        earninginakita = ((earningusd*d/p)-akitaer);

     }else{
        uint earningusd = (amt*(withdraltime-starttime)*APY)/3153600000;
       // earninginusd = (earningusd -usdtear)/2;
        earninginakita = ((earningusd*d/p)-akitaer);
     }
     return (earninginakita);

     }
     function withdrawearning(uint id) public{
    //require (OrdereMap[id].enddate< block.timestamp,"order not complet");
     require (OrdereMap[id].USer== msg.sender,"not your order");
     (uint earninginakita) = earning(id);
    // contractToken.transfer(msg.sender,earninginusd);
     NativeContractToken.transfer(msg.sender,earninginakita);
    // OrdereMap[id].earningwithdralusd+=earninginusd;
     OrdereMap[id].earningwithdralAkita+=earninginakita;
      WeId.increment();
     uint neweID = WeId.current();
     WithdrawEarningMap[neweID] = WithdrawEarning(neweID,id,msg.sender,earninginakita,block.timestamp);
     }

     function getdowline(address addressser) public view returns(address [] memory){
        return user[addressser].downline;
     }
     function get2dowline(address addressser) public view returns(address [] memory){
        return user[addressser].secondLeveldownline;
     }
     function listMyeID() public view returns (WithdrawEarning [] memory){
        uint LockcountItem = WeId.current();
        uint activeTradeCount =0;
        uint current =0;
        for (uint i=0; i< LockcountItem; i++){
            if(WithdrawEarningMap[i+1].USer == msg.sender){
                activeTradeCount +=1;
        }
    }
     WithdrawEarning[] memory items1 = new WithdrawEarning[](activeTradeCount);
      for (uint i=0; i< LockcountItem; i++){
             if(WithdrawEarningMap[i+1].USer == msg.sender){
                uint currentId = WithdrawEarningMap[i+1].id;
                WithdrawEarning storage currentItem = WithdrawEarningMap[currentId];
                items1[current] = currentItem;
                current +=1;
             }
        }
        return items1;

}
function totaluserstaking(address _user) public view returns(uint){
     uint LockcountItem = SId.current();
        uint activeTradeCount =0;
        //uint current =0;
        for (uint i=0; i< LockcountItem; i++){
            if(OrdereMap[i+1].USer == _user){
                activeTradeCount +=OrdereMap[i+1].amount;

        }
    }
        return activeTradeCount;

}
function swap (uint amount) public {
     require( isRegistered(msg.sender) == true,"not registred");
     uint myamount = totaluserstaking(msg.sender);
     uint eligibleusd = (Limit*myamount)/(100);
     uint maxswap = eligibleusd*setdecimal/Price;
    require(swapAmount[msg.sender]+amount<maxswap,"only 20% of swap can be withdrawl");
      NativeContractToken.transferFrom(msg.sender, address(this), amount);
      uint p = Price;
      uint d = setdecimal;
      uint swapamount = (amount*p)/d;
      contractToken.transfer(msg.sender,swapamount);
      swapAmount[msg.sender]+=amount;

}
function swapCommision (uint amount) public {
     require( isRegistered(msg.sender) == true,"not registred");
      CommissionContractToken.transferFrom(msg.sender, address(this), amount);
      uint swapamount = (amount);
      contractToken.transfer(msg.sender,swapamount);


}
function Ownerregister(address _user, address referrer, uint time) public {
    require (msg.sender == owner,"Not an owner");
     require(_user != referrer && !isRegistered(_user), "Invalid registration");
        require(isRegistered(referrer)==true,"Reffral not registred");
        address sencod = user[referrer].sponsore;
        user[_user] = User(_user,referrer,sencod, new address[](0), new address[](0),time,true);
        user[referrer].downline.push(_user);
        user[sencod].secondLeveldownline.push(_user);
        totalParticipants++;
     }
     function OwnerSTAKE (uint amout ,uint day,uint countryid,address _user, uint starttime) public {
         require (msg.sender == owner,"Not an owner");
       require( isRegistered(_user) == true,"User not registred");
       //contractToken.transferFrom(msg.sender, address(this), amout);
       uint APy = ApyLock[day];
       address head = countryhead[countryid];
       address sponser = user[_user].sponsore;
       uint end = starttime+(day*86400);
       address secondSponser = user[_user].secondSsponsore;
       uint one = (amout*Firstlevel)/(100);
       uint two = (amout*Secondlevel)/(100);
       uint he = (amout*HeadPercent)/(100);
        CommissionContractToken.transfer(sponser,one);
        CommissionContractToken.transfer(secondSponser,two);
        CommissionContractToken.transfer(head,he);
       SId.increment();
       uint newID = SId.current();
       OrdereMap[newID] = order(newID,amout,APy,day,starttime,end,false,_user,0,Price,setdecimal,0);
       totaldepsoit+=amout;
       commisionAmount[sponser]+=one;
       commisionAmount[secondSponser]+=two;
       commisionAmount[head]+=he;
     }

}