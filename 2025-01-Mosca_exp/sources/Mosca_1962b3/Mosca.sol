pragma solidity ^0.8.20;


/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}




pragma solidity ^0.8.0;


contract Mosca is ReentrancyGuard{
   
     IERC20 public usdt;
    IERC20 public usdc;

    address public owner;

    struct User {
        uint256 balance; // Total earnings of the user
        uint256 balanceUSDT;
        uint256 balanceUSDC;
        uint256 nextDeadline; // Subscription renewal deadline
        uint256 bonusDeadline;
        uint256 runningCount; // Total active users in the user's network
        uint256 inviteCount; // Total number of personal invites
        uint256 refCode; // Referral code of the user
        uint256 collectiveCode; // Referral code of the group
        address walletAddress;
        bool enterprise;
    }

    mapping(address => User) public users;
    mapping(uint256 => address) public referrers; // Referral code to address mapping
    mapping(address => uint256) public refByAddr; // Address to referral code mapping
    mapping(address => bool) public isBlacklisted;
    address[] public rewardQueue;

    uint256 public JOIN_FEE = 28 * 1e18;
    uint256 public ENTERPRISE_JOIN_FEE = 99 * 1e18;
    uint256 public TAX = 3 * 1e18;
    uint256 public ENTERPRISE_TAX = 9 * 1e18;
    uint256 public TRANSFER_FEE = 50;
    uint8 public gracePeriod = 28; // Grace period in days
    uint256 public totalRevenue;
    uint256 public totalRewards;
    uint256 public adminBalance;
    uint256 public adminBalanceUSDC;
    uint256 public adminBalanceUSDT;

    uint256[] public tierRewards = [250, 125, 125, 125, 125, 125, 63, 63, 63, 187]; // Tier rewards in cents
    uint256[] public enterprise_tierRewards = [750, 375, 375, 375, 375, 375, 189, 189, 189, 561]; // Tier rewards in cents
    uint256[] public tierSizes = [3, 9, 27, 81, 243, 729, 2187, 6561, 19683, 59049]; // Number of users per tier

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    event Joined(address indexed user, uint256 timestamp, uint256 amount, uint8 payType);
    event RewardEarned(address indexed user, uint256 timestamp, uint256 amount);
    event TransferFeeEarned(address indexed user, uint256 timestamp, uint256 amount);
    event BoughtMosca(address indexed user, uint256 timestamp, uint256 amount);
    event BoughtUSDT(address indexed user, uint256 timestamp, uint256 amount);
    event BoughtUSDC(address indexed user, uint256 timestamp, uint256 amount);
    event SubscriptionPaid(address indexed user, uint256 timestamp, uint256 amount);
    event Compressed(address indexed user, uint256 time);
    event Transfer(address indexed from, address indexed to, uint256 timestamp, uint256 amount);
    event TransferUSDC(address indexed from, address indexed to, uint256 timestamp, uint256 amount);
    event TransferUSDT(address indexed from, address indexed to, uint256 timestamp, uint256 amount);
    event WithdrawFiat(address indexed user, uint256 timestamp, uint256 amount, uint8 payType);
    event WithdrawAll(address indexed user, uint256 timestamp, uint256 amount, uint8 payType);
    event EmergencyWithdraw(address indexed user, uint256 timestamp);
    event AdminWithdrawFees(address indexed user, uint256 timestamp, uint256 amount, uint8 payType);
    event Downgrade(address indexed user, uint256 timestamp);
    event ExitProgram(address indexed user, uint256 timeExited);

   

    constructor(
        address _usdt, 
        address _usdc,
        address [] memory addresses,
        uint256 [] memory balances,
        uint256 [] memory deadlines,
        uint256 [] memory bonusDeadlines,
        uint256 [] memory inviteCounts,
        uint256 [] memory refCodes,
        uint256 [] memory collectiveCodes,
        bool [] memory statuses
   

        ) {
        owner = msg.sender;
        usdt = IERC20(_usdt);
        usdc = IERC20(_usdc);
        for(uint i = 0; i < addresses.length; i++){
            User storage user = users[addresses[i]] ;

            user.balance = balances[i];
            user.nextDeadline = deadlines[i];
            user.bonusDeadline = bonusDeadlines[i];
            user.inviteCount = inviteCounts[i];
            user.refCode = refCodes[i];
            user.collectiveCode = collectiveCodes[i];
            user.walletAddress = addresses[i];
            user.enterprise = statuses[i];

             rewardQueue.push(addresses[i]);

             referrers[refCodes[i]] = addresses[i];
        refByAddr[addresses[i]] = refCodes[i];

        }
       
    }

    

function random(address i) private view returns(uint256){
        return uint256(keccak256(abi.encodePacked(block.difficulty, block.timestamp, i))) % 10000000000;
    }


function addReferralAddress(address _addr) private {

        uint256 _referralCode = random(_addr);
        referrers[_referralCode] = _addr;
        refByAddr[_addr] = _referralCode;

        users[_addr].refCode = _referralCode;
        
    }

function getRefByAddr(address _addr) public view returns (uint256){
    return refByAddr[_addr];
}


function generateRefCode(address _addr) public {
    addReferralAddress(_addr);
}

function getUser(address userAddr) external view returns (User memory) {
        return users[userAddr];
    }

    
function getReferrer(uint256 _code) public view returns (address) {
        return referrers[_code];
    }


function getRewardQueue() public view returns (address[] memory){
    return rewardQueue;
}

function getAdminBalances() external view returns (uint256, uint256, uint256){
    return (adminBalance, adminBalanceUSDT, adminBalanceUSDC);
}

 
    function transfer(address to, uint256 amount, uint256 fiat ) external nonReentrant{
        require(msg.sender != address(0), "from address cannot be nonexistent");
        require(users[msg.sender].balance >= amount, "Insufficient balance");

          if(fiat == 1){
            require(users[msg.sender].balanceUSDT >= amount, "Insufficient balance");
             uint256 finalAmount = distributeFeesFiat(msg.sender, amount, 1);
        users[msg.sender].balanceUSDT -= amount;
        users[to].balanceUSDT += finalAmount;
        emit TransferUSDT(msg.sender, to,  block.timestamp, amount);
        } else if (fiat == 2){
            require(users[msg.sender].balanceUSDC >= amount, "Insufficient balance");
             uint256 finalAmount = distributeFeesFiat(msg.sender, amount, 2);
        users[msg.sender].balanceUSDC -= amount;
        users[to].balanceUSDC += finalAmount;
        emit TransferUSDC(msg.sender, to, block.timestamp, amount);
        } else {

            uint256 finalAmount = distributeFees(msg.sender, amount);
        users[msg.sender].balance -= amount;
        users[to].balance += finalAmount;
        emit Transfer(msg.sender, to, block.timestamp, amount);
        }

        

        
    }
    

     function join(uint256 amount, uint256 _refCode, uint8 fiat, bool enterpriseJoin) external nonReentrant{
           User storage user = users[msg.sender];
           uint256 diff = user.balance > 127 * 10 ** 18 ? user.balance - 127 * 10 ** 18 : 0;
            uint256 tax_remainder;

           uint256 baseAmount = ((amount + diff) * 1000) / 1015;
          
       

      
            if(enterpriseJoin) {
                
                if(refByAddr[msg.sender] == 0) {
                    require(amount >= (ENTERPRISE_JOIN_FEE * 3) + (JOIN_FEE * 3), "Insufficient amount sent to join enterprise");
                    if(fiat == 1){
                    require(usdt.transferFrom(msg.sender, address(this), amount - (ENTERPRISE_TAX * 3)), "Transfer failed");
                    require(usdt.transferFrom(msg.sender, owner, ENTERPRISE_TAX * 3), "Transfer tax failed");
                    } else {
                        require(usdc.transferFrom(msg.sender, address(this), amount - (ENTERPRISE_TAX * 3)), "Transfer failed");
                        require(usdc.transferFrom(msg.sender, owner, ENTERPRISE_TAX * 3), "Transfer tax failed");
                    }


                } else {
                    
                    require(amount + diff >= (ENTERPRISE_JOIN_FEE * 3), "Insufficient amount to upgrade to enterprise");
                    if(diff < ENTERPRISE_TAX * 3){
                        tax_remainder = (ENTERPRISE_TAX * 3) - diff;
                        adminBalance+= (ENTERPRISE_TAX * 3) - diff;
                        user.balance -= diff;
                        diff = 0;
                        

                         if(fiat == 1){
                            require(usdt.transferFrom(msg.sender, owner, tax_remainder), "Transfer failed");
                        } else {
                            require(usdc.transferFrom(msg.sender, owner, tax_remainder), "Transfer failed");
                        }

                    } else {
                        adminBalance+= ENTERPRISE_TAX * 3;
                        diff -= ENTERPRISE_TAX * 3;
                         user.balance -= ENTERPRISE_TAX * 3; 
                        if(diff > ENTERPRISE_JOIN_FEE * 3){
                            user.balance -= (ENTERPRISE_JOIN_FEE * 3);
                        } else {
                            user.balance -= diff;
                        }
                       

                    }

                      if(amount > 0) {

                        if(fiat == 1){

                            require(usdt.transferFrom(msg.sender, address(this), amount - tax_remainder), "Transfer failed");

                        } else {

                            require(usdc.transferFrom(msg.sender, address(this), amount - tax_remainder), "Transfer failed");

                        }


                        }
                    
                    

                  

                }
                user.enterprise = true;
            } else {

                require(amount >= JOIN_FEE, "Insufficient amount sent");


                if(fiat == 1){

                    require(usdt.transferFrom(msg.sender, address(this), amount - (TAX * 3)), "Transfer failed");
                    require(usdt.transferFrom(msg.sender, owner, TAX * 3), "Transfer failed");
                } else {

                     require(usdc.transferFrom(msg.sender, address(this), amount - (TAX * 3)), "Transfer failed");
                    require(usdc.transferFrom(msg.sender, owner, TAX * 3), "Transfer failed");

                }


            }
        
        
      
       user.nextDeadline = block.timestamp + 28 days;
       user.bonusDeadline = block.timestamp + 7 days;
       user.walletAddress = msg.sender;
        totalRevenue+= amount;
        user.balance += enterpriseJoin ? baseAmount - ENTERPRISE_JOIN_FEE : baseAmount - JOIN_FEE;

     

        if(referrers[_refCode] != address(0)){
            user.collectiveCode = _refCode;
            users[referrers[user.collectiveCode]].balance += enterpriseJoin && users[referrers[user.collectiveCode]].enterprise ? (((90 * 10 ** 18) * 25 / 100)) : ((25 * 10 ** 18) * 25/ 100);
            users[referrers[user.collectiveCode]].inviteCount++;
            emit RewardEarned(referrers[user.collectiveCode], block.timestamp, enterpriseJoin && users[referrers[user.collectiveCode]].enterprise ? (((90 * 10 ** 18) * 25 / 100)) : ((25 * 10 ** 18) * 25/ 100));
            if(users[referrers[user.collectiveCode]].inviteCount % 3 == 0){
                users[referrers[user.collectiveCode]].balance += enterpriseJoin && users[referrers[user.collectiveCode]].enterprise ? (((90 * 10 ** 18) * 25 / 100)) : ((25 * 10 ** 18) * 25/ 100);
                emit RewardEarned(referrers[user.collectiveCode], block.timestamp, enterpriseJoin && users[referrers[user.collectiveCode]].enterprise ? (((90 * 10 ** 18) * 25 / 100)) : ((25 * 10 ** 18) * 25/ 100));
            }

        }

        rewardQueue.push(msg.sender);

        if(refByAddr[msg.sender] == 0){
        generateRefCode(msg.sender);
        }

        emit Joined(msg.sender, block.timestamp, amount, fiat);

       cascade(msg.sender);

        distributeFees(msg.sender, amount);
        
     }
     function buy(uint256 amount, bool buyFiat, uint8 fiat) external nonReentrant{
        require(refByAddr[msg.sender] != 0, "Cannot buy before activating citizenship");
           User storage user = users[msg.sender];

        uint256 baseAmount = (amount * 1000)/1015;

       
        
          
        totalRevenue+= amount;
        if(!buyFiat){
             user.balance += baseAmount;
             emit BoughtMosca(msg.sender,  block.timestamp, baseAmount);
        } else {
            if(fiat == 1) {
                 user.balanceUSDT += baseAmount;
                 emit BoughtUSDT(msg.sender,  block.timestamp, baseAmount);
            } else {
                user.balanceUSDC += baseAmount;
                emit BoughtUSDC(msg.sender, block.timestamp, baseAmount);
            } 
        }
    

         if(fiat == 1) {
           require(usdt.transferFrom(msg.sender, address(this), amount), "Transfer failed"); 
            
            } else {
                require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
               

            }


        distributeFees(msg.sender, amount);
        
     }


     function swap(uint8 tokentoSwap, uint8 tokentoReceive, uint256 amount) external nonReentrant{
        User storage user = users[msg.sender];

        if(tokentoSwap == 1){
            require(amount <= user.balance, "Insufficient mosca balance");
            if(tokentoReceive == 2){
                user.balance -= amount;
                user.balanceUSDT += amount;
            }
            else if(tokentoReceive == 3){
                user.balance -= amount;
                user.balanceUSDC += amount;
            }
        }
        else if(tokentoSwap == 2){
            require(amount <= user.balanceUSDT, "Insufficient usdt balance");
            if(tokentoReceive == 1){
                user.balanceUSDT -= amount;
                user.balance += amount;
            }
            else if(tokentoReceive == 3){
                user.balanceUSDT -= amount;
                user.balanceUSDC += amount;
            }
        }
        else if(tokentoSwap == 3){
            require(amount <= user.balanceUSDC, "Insufficient usdc balance");
            if(tokentoReceive == 1){
                user.balanceUSDC -= amount;
                user.balance += amount;
            }
            else if(tokentoReceive == 2){
                user.balanceUSDC -= amount;
                user.balanceUSDT += amount;
            }
        }
     }
     

  
     function getCascadeAddressesByRefCode(uint256 refCode) public view returns (address[10] memory) {
       
   address[10] memory referrerArray;
    address currentAddress = referrers[refCode];
    uint256 depth = 0;

    while (currentAddress != address(0) && depth < 10) {
        User memory user = users[currentAddress];
        referrerArray[depth] = getReferrer(user.refCode); // Add the referrer's wallet address to the array
        currentAddress = referrers[user.collectiveCode]; // Update to the next referrer
        depth++;
    }

    return referrerArray;
}

  

   

   function cascade(address tempAddress) private {
    User storage user = users[tempAddress];
    address referrer = referrers[user.collectiveCode];
    uint256 depth = 0;
   

    while (referrer != address(0) && depth < 10) {

        if(users[referrer].inviteCount < 3 && depth >= 2){

            depth++;

        } else {

        

                // Add rewards for the current referrer
                if(users[referrer].enterprise) {
                
                users[referrer].balance += (enterprise_tierRewards[depth] * 10 ** 18) / 100;
                emit RewardEarned(referrer, block.timestamp, (enterprise_tierRewards[depth] * 10 ** 18) / 100);

              
                } else {
                users[referrer].balance += (tierRewards[depth] * 10 ** 18) / 100;
                emit RewardEarned(referrer,  block.timestamp, (tierRewards[depth] * 10 ** 18) / 100);
               
                }

    

             depth++;

        }
                
             
        

        // Update to the next referrer in the chain
        referrer = referrers[users[referrer].collectiveCode];
        
    }
}

function distributeFees(address tempAddress, uint256 amount) private returns (uint256) {
    User storage user = users[tempAddress];
    address referrer = referrers[user.collectiveCode];
    uint256 finalAmount = (amount * 1000) / 1015;

    uint256 processingFee = finalAmount / 100;

    adminBalance += processingFee;
    
    if(referrers[users[referrer].collectiveCode] == address(0)){
        users[referrer].balance += (finalAmount * TRANSFER_FEE) / 10000;
        emit TransferFeeEarned(referrer,  block.timestamp, (finalAmount * TRANSFER_FEE) / 10000);
        
    } else {
       users[referrer].balance +=(((finalAmount * TRANSFER_FEE) / 10000)/2);
       users[referrers[users[referrer].collectiveCode]].balance += (((finalAmount * TRANSFER_FEE) / 10000)/2);
       emit TransferFeeEarned(referrer, block.timestamp, (((finalAmount * TRANSFER_FEE) / 10000)/2));
       emit TransferFeeEarned(referrers[users[referrer].collectiveCode],  block.timestamp, (((finalAmount * TRANSFER_FEE) / 10000)/2));
       
    }

    

    return finalAmount;

    
}
function distributeFeesFiat(address tempAddress, uint256 amount, uint256 fiat) private returns (uint256) {
    User storage user = users[tempAddress];
    address referrer = referrers[user.collectiveCode];
    uint256 finalAmount = (amount * 1000) / 1015;

    uint256 processingFee = finalAmount / 100;

    fiat == 1 ? adminBalanceUSDT += processingFee : adminBalanceUSDC += processingFee;

    if(referrers[users[referrer].collectiveCode] == address(0)){
        fiat == 1 ? users[referrer].balanceUSDT += (finalAmount * TRANSFER_FEE) / 10000 : users[referrer].balanceUSDC += (finalAmount * TRANSFER_FEE) / 10000;
        emit TransferFeeEarned(referrer, block.timestamp, (finalAmount * TRANSFER_FEE) / 10000);
    } else {
       fiat == 1 ? users[referrer].balanceUSDT += (((finalAmount * TRANSFER_FEE) / 10000)/2) : users[referrer].balanceUSDC += (((finalAmount * TRANSFER_FEE) / 10000)/2);
       fiat == 1 ? users[referrers[users[referrer].collectiveCode]].balanceUSDT += (((finalAmount * TRANSFER_FEE) / 10000)/2) : users[referrers[users[referrer].collectiveCode]].balanceUSDC += (((finalAmount * TRANSFER_FEE) / 10000)/2);
       emit TransferFeeEarned(referrer, block.timestamp, (((finalAmount * TRANSFER_FEE) / 10000)/2));
       emit TransferFeeEarned(referrers[users[referrer].collectiveCode], block.timestamp, (((finalAmount * TRANSFER_FEE) / 10000)/2));
    }

    return finalAmount;

    
}


    // Compress inactive users
    function compress() public onlyOwner {
    for (uint256 i = rewardQueue.length; i > 0; i--) {
    address userAddr = rewardQueue[i - 1];
        User storage user = users[userAddr];

        if(block.timestamp >= user.nextDeadline){
        // Deduct subscription fee if balance is sufficient
        if (user.enterprise) {
            if (user.balance >= ENTERPRISE_JOIN_FEE) {
                user.balance -= ENTERPRISE_JOIN_FEE;
                adminBalance += ENTERPRISE_TAX;
                user.nextDeadline = block.timestamp + 28 days;
                cascade(userAddr);
                 emit SubscriptionPaid(userAddr, block.timestamp, ENTERPRISE_JOIN_FEE);
            } else if (user.balance > 0) {
                adminBalance += user.balance;
                user.balance = 0;
                emit SubscriptionPaid(userAddr, block.timestamp, user.balance);
                user.enterprise = false;
                emit Downgrade(userAddr, block.timestamp);
            }
             
        } else {
            if (user.balance >= JOIN_FEE) {
                user.balance -= JOIN_FEE;
                user.nextDeadline = block.timestamp + 28 days;
                cascade(userAddr);
                 emit SubscriptionPaid(userAddr, block.timestamp, ENTERPRISE_JOIN_FEE);
            } else if (user.balance > 0) {
                adminBalance += user.balance;
                user.balance = 0;
                 emit SubscriptionPaid(userAddr, block.timestamp, user.balance);
            }
           
        }

        if (block.timestamp > user.nextDeadline + (gracePeriod * 1 days)) {
                // Avoid reprocessing already-compressed users
                if (refByAddr[userAddr] == 0 && referrers[user.refCode] == address(0x000000000000000000000000000000000000dEaD)) {
                    continue;
                }

                // Decrement running counts for uplines
                address referrer = referrers[user.collectiveCode];
                if (referrer != address(0)) {
                    users[referrer].inviteCount--;
                }

                // Update referrer mappings
                refByAddr[userAddr] = 0;
                referrers[user.refCode] = 0x000000000000000000000000000000000000dEaD;

                // Remove user from reward queue
                rewardQueue[i - 1] = rewardQueue[rewardQueue.length - 1];
                rewardQueue.pop();
                emit Compressed(userAddr, block.timestamp);
            }

          

          
           
        
        }
    }
}
   
    // Compress inactive users
    function compressSection(uint256 start, uint256 end) public onlyOwner {
    for (uint256 i = end; i > start; i--) {
    address userAddr = rewardQueue[i - 1];
        User storage user = users[userAddr];

        if(block.timestamp >= user.nextDeadline){
        // Deduct subscription fee if balance is sufficient
        if (user.enterprise) {
            if (user.balance >= ENTERPRISE_JOIN_FEE) {
                user.balance -= ENTERPRISE_JOIN_FEE;
                adminBalance += ENTERPRISE_TAX;
                user.nextDeadline = block.timestamp + 28 days;
                cascade(userAddr);
                emit SubscriptionPaid(userAddr, block.timestamp, ENTERPRISE_JOIN_FEE);
            } else if (user.balance > 0) {
                adminBalance += user.balance;
                user.balance = 0;
                emit SubscriptionPaid(userAddr, block.timestamp, user.balance);
                 user.enterprise = false;
                emit Downgrade(userAddr, block.timestamp);
            }
            
        } else {
            if (user.balance >= JOIN_FEE) {
                user.balance -= JOIN_FEE;
                user.nextDeadline = block.timestamp + 28 days;
                cascade(userAddr);
                emit SubscriptionPaid(userAddr, block.timestamp, JOIN_FEE);
            } else if (user.balance > 0) {
                adminBalance += user.balance;
                user.balance = 0;
                emit SubscriptionPaid(userAddr, block.timestamp, user.balance);
            }
            
        }

        // Check if user has exceeded the grace period
        if (block.timestamp > user.nextDeadline + (gracePeriod * 1 days)) {
                // Avoid reprocessing already-compressed users
                if (refByAddr[userAddr] == 0 && referrers[user.refCode] == address(0x000000000000000000000000000000000000dEaD)) {
                    continue;
                }

                // Decrement running counts for uplines
                address referrer = referrers[user.collectiveCode];
                if (referrer != address(0)) {
                    users[referrer].inviteCount--;
                }

                // Update referrer mappings
                refByAddr[userAddr] = 0;
                referrers[user.refCode] = 0x000000000000000000000000000000000000dEaD;

                // Remove user from reward queue
                rewardQueue[i - 1] = rewardQueue[rewardQueue.length - 1];
                rewardQueue.pop();
                emit Compressed(userAddr, block.timestamp);
            }
        }
    }
}



// Compress inactive users
   function exitProgram() external nonReentrant {
    require(!isBlacklisted[msg.sender], "Blacklisted user");
    User storage user = users[msg.sender];

    address referrer = referrers[user.collectiveCode];
    if (referrer != address(0) && users[referrer].inviteCount > 0) {
        users[referrer].inviteCount--;
    }

    for (uint256 i = 0; i < rewardQueue.length; i++) {
        address userAddr = rewardQueue[i];
        if (userAddr == msg.sender) {
            // Perform withdrawal before modifying user state
            withdrawAll(msg.sender);

            // Remove user from reward queue and reset state
            refByAddr[userAddr] = 0;
            referrers[user.refCode] = 0x000000000000000000000000000000000000dEaD;
            user.balance = 0;
            user.enterprise = false;

            rewardQueue[i] = rewardQueue[rewardQueue.length - 1];
            rewardQueue.pop();

            emit ExitProgram(msg.sender, block.timestamp);
        }
    }
}
   
    


    

    
    
    function withdrawFiat(uint256 amount, bool isFiat, uint8 fiatToWithdraw) external nonReentrant {
        require(!isBlacklisted[msg.sender], "Blacklisted user");
         User storage user = users[msg.sender];
         uint limit = user.enterprise ? 127 * 10 ** 18 : 28 * 10 ** 18;
         uint balance; 
          uint256 baseAmount = (amount * 1000) / 1015;
         if(!isFiat) {
             balance = user.balance; 

         } else {
              balance = fiatToWithdraw == 1 ? user.balanceUSDT  : user.balanceUSDC ;
         }

          require(amount <= balance - limit, "Insufficient balance");

          if (!isFiat){
            user.balance -= amount;
          }
          else {
           fiatToWithdraw == 1 ? user.balanceUSDT -= amount  : user.balanceUSDC -= amount ;
          }
           
       
        

        fiatToWithdraw == 1 ? usdt.transfer(msg.sender, baseAmount) : usdc.transfer(msg.sender, baseAmount);

        if(!isFiat) {
            
            distributeFees(msg.sender, amount);
             
         } else {
              distributeFeesFiat(msg.sender, amount, fiatToWithdraw);
         }
        

        emit WithdrawFiat(msg.sender, block.timestamp, amount, fiatToWithdraw);

        

    }
    
    function admin_WithdrawFees_Mosca(uint256 amount, uint8 fiatToWithdraw) external onlyOwner {
        uint balance = adminBalance;
        require(amount <= balance , "Amount exceeds to balance in contract");
        if(fiatToWithdraw == 1){
            require(amount <= usdt.balanceOf(address(this)), "Insufficient amount of USDT in contract to cover withdrawal");
            usdt.transfer(msg.sender, amount);
        } else {
            require(amount <= usdc.balanceOf(address(this)), "Insufficient amount of USDC in contract to cover withdrawal");
            usdc.transfer(msg.sender, amount);
        }
        adminBalance -= amount;

        emit AdminWithdrawFees(msg.sender, block.timestamp, amount, fiatToWithdraw);

    }
    function admin_WithdrawFees_Fiat(uint256 amount, uint8 fiatToWithdraw) external onlyOwner {
        uint balance = fiatToWithdraw == 1 ? adminBalanceUSDT : adminBalanceUSDC;
        require(amount <= balance , "Amount exceeds to balance in contract");
        if(fiatToWithdraw == 1){
            require(amount <= usdt.balanceOf(address(this)), "Insufficient amount of USDT in contract to cover withdrawal");
            adminBalanceUSDT -= amount;
            usdt.transfer(msg.sender, amount);
             
        } else {
            require(amount <= usdc.balanceOf(address(this)), "Insufficient amount of USDC in contract to cover withdrawal");
            adminBalanceUSDC -= amount;
            usdc.transfer(msg.sender, amount);
            
        }
       

        emit AdminWithdrawFees(msg.sender, block.timestamp, amount, fiatToWithdraw);

    }
    
    function withdrawAll(address addr) private {
         User storage user = users[addr];
        require(msg.sender == user.walletAddress, "Wallet addresses do not match");
        uint balance = user.balance + user.balanceUSDT + user.balanceUSDC;

        if(usdc.balanceOf(address(this)) >= balance){
            usdc.transfer(user.walletAddress, balance);
            emit WithdrawAll(user.walletAddress, block.timestamp, balance, 2);
        } else {
            usdt.transfer(user.walletAddress, balance);
            emit WithdrawAll(user.walletAddress, block.timestamp, balance, 1);
        }
        

       

    }

   function transferOwnership(address _newAddr) external onlyOwner {
    owner = _newAddr;
   }

   function setUSDTAddress(address _newAddr) external onlyOwner {
    usdt = IERC20(_newAddr);
   }

   function setUSDCAddress(address _newAddr) external onlyOwner {
    usdc = IERC20(_newAddr);
   }

   function setUserBalance(address addr, uint amount) external onlyOwner {
    users[addr].balance = amount;
   }

   function setCollectiveCode(address addr, uint _code) external onlyOwner {
    users[addr].collectiveCode = _code;
   }

  

   function addBlacklistedUsers(address [1] memory addresses) external onlyOwner {
    for(uint i = 0; i < addresses.length; i++){
        isBlacklisted[addresses[i]] = true;
    }
   }
   function removeBlacklistedUsers(address [] memory addresses) external onlyOwner {
    for(uint i = 0; i < addresses.length; i++){
        isBlacklisted[addresses[i]] = false;
    }
   }

   /**Emergency Admin Withdraw is to be used only in the event of an exploit that requires immediate action. 
   * Function will be unusable upon renouncing of ownership.*/
   function emergencyWithdraw() external onlyOwner {
    require(usdt.transfer(owner, usdt.balanceOf(address(this))));
    require(usdc.transfer(owner, usdc.balanceOf(address(this))));

    emit EmergencyWithdraw(msg.sender, block.timestamp);
   }

   
 


}