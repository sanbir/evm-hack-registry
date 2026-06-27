//Team Token Locking Contract
pragma solidity 0.6.2;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC721/IERC721Enumerable.sol";
import "./interfaces/IERC20Extended.sol";
import "./interfaces/IPriceEstimator.sol";
import "./interfaces/IV3Migrator.sol";
import "./interfaces/IERC721Extended.sol";
import "./interfaces/IUniswapV3PositionManager.sol";

contract LockToken is Initializable, OwnableUpgradeSafe, PausableUpgradeSafe, IERC721Receiver{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Address for address;
    /*
     * deposit vars
    */
    struct Items {
        address tokenAddress;
        address withdrawalAddress;
        uint256 tokenAmount;
        uint256 unlockTime;
        bool withdrawn;
    }

    struct NFTItems {
        address tokenAddress;
        address withdrawalAddress;
        uint256 tokenAmount;
        uint256 unlockTime;
        bool withdrawn;
        uint256 tokenId;
    }

    uint256 public depositId;
    uint256[] public allDepositIds;
    mapping(address => uint256[]) public depositsByWithdrawalAddress;
    mapping(uint256 => Items) public lockedToken;
    mapping(address => mapping(address => uint256)) public walletTokenBalance;
    /*
     * Fee vars
    */
    address public usdTokenAddress;
    IPriceEstimator public priceEstimator;
    //feeInUSD is in Wei, i.e 25USD = 25000000 USDT
    uint256 public feesInUSD;
    address payable public companyWallet;
    //list of free tokens
    mapping(address => bool) private listFreeTokens;

    mapping (uint256 => NFTItems) public lockedNFTs;
    
    //migrating liquidity
    IERC721Enumerable public nonfungiblePositionManager;
    IV3Migrator public v3Migrator;
    //new deposit id to old deposit id
    mapping(uint256 => uint256) public listMigratedDepositIds;

    //NFT Liquidity
    mapping(uint256 => bool) public nftMinted;
    address public NFT;
    bool private _notEntered;

    uint256 private constant MAX_PERCENTAGE = 10000;

    uint256 public referralDiscount;
    uint256 public referrerCut;

    // mapping of whitelisted wallet addresses
    mapping(address => bool) public whitelistedWallets;
    // mapping of admins that can whitelist
    mapping (address => bool) public whitelistAdmins;

    event LogTokenWithdrawal(uint256 id, address indexed tokenAddress, address indexed withdrawalAddress, uint256 amount);
    event LogNFTWithdrawal(uint256 id, address indexed tokenAddress, uint256 tokenId, address indexed withdrawalAddress, uint256 amount);
    event FeesChanged(uint256 indexed fees);
    event ReferralParamsChanged(uint256 referralDiscount, uint256 referrerCut);
    event ReferrerRewarded(address indexed addr, uint256 referrerCut);
    // event LiquidityMigrated(address indexed migrator, uint256 oldDepositId, uint256 newDepositId, uint256 v3TokenId);
    // event EthReceived(address, uint256);
    event Deposit(uint256 id, address indexed tokenAddress, address indexed withdrawalAddress, uint256 amount, uint256 unlockTime);
    event DepositNFT(uint256 id, address indexed tokenAddress, uint256 tokenId, address indexed withdrawalAddress, uint256 amount, uint256 unlockTime);
    event LockDurationExtended(uint256 id, uint256 unlockTime);
    event LockSplit(uint256 id, uint256 remainingAmount, uint256 splitLockId, uint256 newSplitLockAmount);
    event CompanyWalletUpdated(address companyWallet);
    event NftContractUpdated(address nftContract);
    event FreeTokenListUpdated(address token, bool isFree);
    event WhiteListUpdated(address wallet, bool noFee);
    event WhiteListAdminUpdated(address wallet, bool status);

    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_notEntered, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _notEntered = false;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _notEntered = true;
    }

    modifier onlyContract(address account)
    {
        require(account.isContract(), "The address does not contain a contract");
        _;
    }

    /**
    * @dev initialize
    */
    function initialize()
    external
    {
        __LockToken_init();
    }

    function __LockToken_init()
    internal
    initializer
    {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        _notEntered = true;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     *lock tokens
    */
    function lockToken(
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _amount,
        uint256 _unlockTime,
        bool _mintNFT,
        address referrer
    )
    external 
    payable
    whenNotPaused
    nonReentrant
    returns (uint256 _id)
    {
        require(_amount > 0, "Amount is zero");
        require(_unlockTime > block.timestamp, "Invalid unlock time");
        uint256 amountIn = _amount;

        referrer == address(0) ? _chargeFees(_tokenAddress) : _chargeFeesReferral(_tokenAddress, referrer);
            
        uint256 balanceBefore = IERC20(_tokenAddress).balanceOf(address(this));
        // transfer tokens into contract
        IERC20(_tokenAddress).safeTransferFrom(_msgSender(), address(this), _amount);
        amountIn = IERC20(_tokenAddress).balanceOf(address(this)).sub(balanceBefore);

        //update balance in address
        walletTokenBalance[_tokenAddress][_withdrawalAddress] = walletTokenBalance[_tokenAddress][_withdrawalAddress].add(amountIn);
        _id = _addERC20Deposit(_tokenAddress, _withdrawalAddress, amountIn, _unlockTime);

        if(_mintNFT) {
            _mintNFTforLock(_id, _withdrawalAddress);
        }

        emit Deposit(_id, _tokenAddress, _withdrawalAddress, amountIn, _unlockTime);
    }

    /**
     *lock nft
    */
    function lockNFT(
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _amount,
        uint256 _unlockTime,
        uint256 _tokenId,
        bool _mintNFT,
        address referrer
    )
    external 
    payable
    whenNotPaused
    nonReentrant
    returns (uint256 _id)
    {
        require(_amount == 1, "Invalid amount");
        require(_unlockTime > block.timestamp, "Invalid unlock time");

        referrer == address(0) ? _chargeFees(_tokenAddress) : _chargeFeesReferral(_tokenAddress, referrer);

        //update balance in address
        walletTokenBalance[_tokenAddress][_withdrawalAddress] = walletTokenBalance[_tokenAddress][_withdrawalAddress].add(_amount);
        _id = ++depositId;
        lockedNFTs[_id] = NFTItems({
            tokenAddress: _tokenAddress, 
            withdrawalAddress: _withdrawalAddress,
            tokenAmount: _amount,
            unlockTime: _unlockTime,
            withdrawn: false,
            tokenId: _tokenId
        });

        allDepositIds.push(_id);
        depositsByWithdrawalAddress[_withdrawalAddress].push(_id);

        if(_mintNFT) {
            _mintNFTforLock(_id, _withdrawalAddress);
        }
        IERC721(_tokenAddress).safeTransferFrom(_msgSender(), address(this), _tokenId);

        emit DepositNFT(_id, _tokenAddress, _tokenId, _withdrawalAddress, _amount, _unlockTime);
    }

    /**
     *Extend lock Duration
    */
    function extendLockDuration(
        uint256 _id,
        uint256 _unlockTime
    )
    external nonReentrant
    {
        require(_unlockTime > block.timestamp, "Invalid unlock time");
        NFTItems storage lockedNFT = lockedNFTs[_id];
        Items storage lockedERC20 = lockedToken[_id];

        if(nftMinted[_id]) {
            require(IERC721Extended(NFT).ownerOf(_id) == _msgSender(), "Unauthorised to extend");
        } else {
            require((_msgSender() == lockedNFT.withdrawalAddress || 
                _msgSender() == lockedERC20.withdrawalAddress),
                "Unauthorised to extend"
            );
        }

        if(lockedNFT.tokenAddress != address(0x0))
        {
            require(_unlockTime > lockedNFT.unlockTime, "NFT: smaller unlockTime than existing");
            require(!lockedNFT.withdrawn, "NFT: already withdrawn");

            //set new unlock time
            lockedNFT.unlockTime = _unlockTime;
        }
        else
        {
            require(
                _unlockTime > lockedERC20.unlockTime,
                "ERC20: smaller unlockTime than existing"
            );
            require(
                !lockedERC20.withdrawn,
                "ERC20: already withdrawn"
            );

            //set new unlock time
            lockedERC20.unlockTime = _unlockTime;
        }
        emit LockDurationExtended(_id, _unlockTime);
    }

    /**
     *transfer locked tokens
    */
    function transferLocks(
        uint256 _id,
        address _receiverAddress
    )
    external nonReentrant
    {
        address msg_sender;
        NFTItems storage lockedNFT = lockedNFTs[_id];
        Items storage lockedERC20 = lockedToken[_id];

        if( lockedNFT.tokenAddress != address(0x0) )
        {
            if (_msgSender() == NFT && nftMinted[_id])
            {
                msg_sender = lockedNFT.withdrawalAddress;
            }
            else
            {
                require((!nftMinted[_id]), "NFT: Transfer Lock NFT");
                require(_msgSender() == lockedNFT.withdrawalAddress, "Unauthorised to transfer");
                msg_sender = _msgSender();
            }
            require(!lockedNFT.withdrawn, "NFT: already withdrawn");
            require(msg_sender != _receiverAddress, "Cannot transfer to self");

            //decrease sender's token balance
            walletTokenBalance[lockedNFT.tokenAddress][msg_sender] = 
                walletTokenBalance[lockedNFT.tokenAddress][msg_sender].sub(lockedNFT.tokenAmount);
            
            //increase receiver's token balance
            walletTokenBalance[lockedNFT.tokenAddress][_receiverAddress] = 
                walletTokenBalance[lockedNFT.tokenAddress][_receiverAddress].add(lockedNFT.tokenAmount);
            
            _removeDepositsForWithdrawalAddress(_id, msg_sender);
            
            //Assign this id to receiver address
            lockedNFT.withdrawalAddress = _receiverAddress;
        }
        else
        {
            if (_msgSender() == NFT && nftMinted[_id])
            {
                msg_sender = lockedERC20.withdrawalAddress;
            }
            else {
                require((!nftMinted[_id]), "ERC20: Transfer Lock NFT");
                require(_msgSender() == lockedERC20.withdrawalAddress, "Unauthorised to transfer");
                msg_sender = _msgSender();
            }
            
            require(!lockedERC20.withdrawn, "ERC20: already withdrawn");
            require(msg_sender != _receiverAddress, "Cannot transfer to self");

            //decrease sender's token balance
            walletTokenBalance[lockedERC20.tokenAddress][msg_sender] = 
            walletTokenBalance[lockedERC20.tokenAddress][msg_sender].sub(lockedERC20.tokenAmount);
            
            //increase receiver's token balance
            walletTokenBalance[lockedERC20.tokenAddress][_receiverAddress] = 
            walletTokenBalance[lockedERC20.tokenAddress][_receiverAddress].add(lockedERC20.tokenAmount);
            
            _removeDepositsForWithdrawalAddress(_id, msg_sender);
            
            //Assign this id to receiver address
            lockedERC20.withdrawalAddress = _receiverAddress;
        }
        
        depositsByWithdrawalAddress[_receiverAddress].push(_id);
    }

    /**
     *withdraw tokens
    */
    function withdrawTokens(
        uint256 _id,
        uint256 _amount
    )
    external
    nonReentrant
    {
        if(nftMinted[_id]) {
            require(IERC721Extended(NFT).ownerOf(_id) == _msgSender(), "Unauthorised to unlock");
        }
        NFTItems memory lockedNFT = lockedNFTs[_id];
        Items storage lockedERC20 = lockedToken[_id];

        require(
            (_msgSender() == lockedNFT.withdrawalAddress || _msgSender() == lockedERC20.withdrawalAddress),
            "Unauthorised to unlock"
        );

        //amount is ignored for erc-721 locks, in the future if 1155 locks are supported, we need to cater to amount var
        if(lockedNFT.tokenAddress != address(0x0)) {
            require(block.timestamp >= lockedNFT.unlockTime, "Unlock time not reached");
            require(!lockedNFT.withdrawn, "NFT: already withdrawn");

            _removeNFTDeposit(_id);

            if(nftMinted[_id])
            {
                nftMinted[_id] = false;
                IERC721Extended(NFT).burn(_id);
            }

            // transfer tokens to wallet address
            IERC721(lockedNFT.tokenAddress).safeTransferFrom(address(this), _msgSender(), lockedNFT.tokenId);

            emit LogNFTWithdrawal(_id, lockedNFT.tokenAddress, lockedNFT.tokenId, _msgSender(), lockedNFT.tokenAmount);
        }
        else
        {
            require(block.timestamp >= lockedERC20.unlockTime, "Unlock time not reached");
            require(!lockedERC20.withdrawn, "ERC20: already withdrawn");
            require(_amount > 0, "ERC20: Cannot Withdraw 0 Tokens");
            require(lockedERC20.tokenAmount >= _amount, "Insufficent Balance to withdraw");

            //full withdrawl
            if(lockedERC20.tokenAmount == _amount){
                _removeERC20Deposit(_id);
                if (nftMinted[_id]){
                    nftMinted[_id] = false;
                    IERC721Extended(NFT).burn(_id);
                }
            }
            else {
                //partial withdrawl
                lockedERC20.tokenAmount = lockedERC20.tokenAmount.sub(_amount);
                walletTokenBalance[lockedERC20.tokenAddress][lockedERC20.withdrawalAddress] = 
                    walletTokenBalance[lockedERC20.tokenAddress][lockedERC20.withdrawalAddress].sub(_amount);
            }
            // transfer tokens to wallet address
            IERC20(lockedERC20.tokenAddress).safeTransfer(_msgSender(), _amount);

            emit LogTokenWithdrawal(_id, lockedERC20.tokenAddress, _msgSender(), _amount);
        }
    }

    /**
    Split existing ERC20 Lock into 2
    @dev This function will split a single lock into two induviual locks
    @param _id represents the lockId of the token lock you are to split
    @param _splitAmount is the amount of tokens in wei that will be 
    shifted from the old lock to the new split lock
    @param _splitUnlockTime the unlock time for the newly created split lock
    must always be >= to unlockTime of lock it is being split from
    @param _mintNFT is a boolean check on weather the new split lock will have an NFT minted
     */
     
    function splitLock(
        uint256 _id, 
        uint256 _splitAmount,
        uint256 _splitUnlockTime,
        bool _mintNFT
    ) 
    external 
    payable
    whenNotPaused
    nonReentrant
    returns (uint256 _splitLockId)
    {
        require(_splitAmount > 0, "Amount is zero");
        Items storage lockedERC20 = lockedToken[_id];
        // NFTItems memory lockedNFT = lockedNFTs[_id];
        address lockedNFTAddress = lockedNFTs[_id].tokenAddress;
        //Check to ensure an NFT lock is not being split
        require(lockedNFTAddress == address(0x0), "Can't split locked NFT");
        uint256 lockedERC20Amount = lockedToken[_id].tokenAmount;
        address lockedERC20Address = lockedToken[_id].tokenAddress;
        address lockedERC20WithdrawlAddress = lockedToken[_id].withdrawalAddress;
        require(lockedERC20Address != address(0x0), "Can't split empty lock");
        if(nftMinted[_id]){
            require(
                IERC721(NFT).ownerOf(_id) == _msgSender(),
                "Unauthorised to Split"
            );
        }
        require(
            _msgSender() == lockedERC20WithdrawlAddress,
             "Unauthorised to Split"
        );
        require(!lockedERC20.withdrawn, "Cannot split withdrawn lock");
        //Current locked tokenAmount must always be > _splitAmount as (lockedERC20.tokenAmount - _splitAmount) 
        //will be the number of tokens retained in the original lock, while splitAmount will be the amount of tokens
        //transferred to the new lock
        require(lockedERC20Amount > _splitAmount, "Insufficient balance to split");
        require(_splitUnlockTime >= lockedERC20.unlockTime, "Smaller unlock time than existing");
        //charge Tier 2 fee for tokenSplit
        _chargeFees(lockedERC20Address);
        lockedERC20.tokenAmount = lockedERC20Amount.sub(_splitAmount);
        //new token lock created with id stored in var _splitLockId
        _splitLockId = _addERC20Deposit(lockedERC20Address, lockedERC20WithdrawlAddress, _splitAmount, _splitUnlockTime);
        if(_mintNFT) {
            _mintNFTforLock(_splitLockId, lockedERC20WithdrawlAddress);
        }
        emit LockSplit(_id, lockedERC20.tokenAmount, _splitLockId, _splitAmount);
        emit Deposit(_splitLockId, lockedERC20Address, lockedERC20WithdrawlAddress, _splitAmount, _splitUnlockTime);

    }

    /**
    * @dev Called by an admin to pause, triggers stopped state.
    */
    function pause()
    external
    onlyOwner 
    {
        _pause();
    }

    /**
    * @dev Called by an admin to unpause, returns to normal state.
    */
    function unpause()
    external
    onlyOwner
    {
        _unpause();
    }

    function setFeeParams(address _priceEstimator, address _usdTokenAddress, uint256 _feesInUSD, address payable _companyWallet)
    external
    onlyOwner
    onlyContract(_priceEstimator)
    onlyContract(_usdTokenAddress)
    {
        require(_feesInUSD > 0, "fees should be greater than 0");
        require(_companyWallet != address(0), "Invalid wallet address");
        priceEstimator = IPriceEstimator(_priceEstimator);
        usdTokenAddress = _usdTokenAddress;
        feesInUSD = _feesInUSD;
        companyWallet = _companyWallet;
        emit FeesChanged(_feesInUSD);
    }

    function setFeesInUSD(uint256 _feesInUSD)
    external
    onlyOwner
    {
        require(_feesInUSD > 0,"fees should be greater than 0");
        feesInUSD = _feesInUSD;
        emit FeesChanged(_feesInUSD);
    }

    function setReferralParams(uint256 _referralDiscount, uint256 _referrerCut)
    external
    onlyOwner
    {
        require(_referralDiscount <= MAX_PERCENTAGE, "Referral discount invalid");
        require(_referrerCut <= MAX_PERCENTAGE, "Referrer cut invalid");

        referralDiscount = _referralDiscount;
        referrerCut = _referrerCut;

        emit ReferralParamsChanged(_referralDiscount, _referrerCut);
    }

    function setCompanyWallet(address payable _companyWallet)
    external
    onlyOwner
    {
        require(_companyWallet != address(0), "Invalid wallet address");
        companyWallet = _companyWallet;

        emit CompanyWalletUpdated(_companyWallet);
    }

    /**
     * @dev Update the address of the NFT SC
     * @param _nftContractAddress The address of the new NFT SC
     */
    function setNFTContract(address _nftContractAddress)
    external
    onlyOwner
    onlyContract(_nftContractAddress)
    {
        NFT = _nftContractAddress;

        emit NftContractUpdated(_nftContractAddress);
    }

    /**
    * @dev called by admin to add given token to free tokens list
    */
    function addTokenToFreeList(address token)
    external
    onlyOwner
    onlyContract(token)
    {
        listFreeTokens[token] = true;

        emit FreeTokenListUpdated(token, true);
    }

    /**
    * @dev called by admin to remove given token from free tokens list
    */
    function removeTokenFromFreeList(address token)
    external
    onlyOwner
    onlyContract(token)
    {
        listFreeTokens[token] = false;

        emit FreeTokenListUpdated(token, false);
    }

     /**
    * @dev called by admin/owner to add add or remove wallet from whitelist
    * @param wallet address to add/remove from whitelist
    * @param noFee if to add or remove from whitelist
    */
    function updateWhitelist(address wallet, bool noFee)
    external
    {
        require(
            (whitelistAdmins[_msgSender()] || owner() == _msgSender()),
            "Caller is not authorized to whitelist"
        );
        whitelistedWallets[wallet] = noFee;
        emit WhiteListUpdated(wallet, noFee);
    }


    /*get total token balance in contract*/
    function getTotalTokenBalance(address _tokenAddress) view external returns (uint256)
    {
       return IERC20(_tokenAddress).balanceOf(address(this));
    }
    
    /*get allDepositIds*/
    function getAllDepositIds() view external returns (uint256[] memory)
    {
        return allDepositIds;
    }
    
    /*get getDepositDetails*/
    function getDepositDetails(uint256 _id)
    view
    external
    returns (
        address _tokenAddress, 
        address _withdrawalAddress, 
        uint256 _tokenAmount, 
        uint256 _unlockTime, 
        bool _withdrawn, 
        uint256 _tokenId,
        bool _isNFT,
        uint256 _migratedLockDepositId,
        bool _isNFTMinted)
    {
        bool isNftMinted = nftMinted[_id];
        NFTItems memory lockedNFT = lockedNFTs[_id];
        Items memory lockedERC20 = lockedToken[_id];

        if( lockedNFT.tokenAddress != address(0x0) )
        {
            // //old lock id
            // uint256 migratedLockId = listMigratedDepositIds[_id];

            return (
                lockedNFT.tokenAddress,
                lockedNFT.withdrawalAddress,
                lockedNFT.tokenAmount,
                lockedNFT.unlockTime,
                lockedNFT.withdrawn, 
                lockedNFT.tokenId,
                true,
                0,
                isNftMinted
            );
        }
        else
        {
            return (
                lockedERC20.tokenAddress,
                lockedERC20.withdrawalAddress,
                lockedERC20.tokenAmount,
                lockedERC20.unlockTime,
                lockedERC20.withdrawn,
                0,
                false,
                0,
                isNftMinted
            );
        }
    }
    
    /*get DepositsByWithdrawalAddress*/
    function getDepositsByWithdrawalAddress(address _withdrawalAddress) view external returns (uint256[] memory)
    {
        return depositsByWithdrawalAddress[_withdrawalAddress];
    }
    
    function getFeesInETH(address _tokenAddress)
    public
    view
    returns (uint256)
    {
        //token listed free or fee params not set
        if (whitelistedWallets[_msgSender()] || 
            isFreeToken(_tokenAddress) ||
            feesInUSD == 0 ||
            address(priceEstimator) == address(0) ||
            usdTokenAddress == address(0) 
            )
        {
            return 0;
        }
        else 
        {
            if (priceEstimator.getUseOracle()) {
                return priceEstimator.getFeeInETHWithOracle(feesInUSD);
            }
            //price should be estimated by 1 token because Uniswap algo changes price based on large amount
            uint256 tokenBits = 10 ** uint256(IERC20Extended(usdTokenAddress).decimals());

            uint256 estFeesInEthPerUnit = priceEstimator.getEstimatedETHforERC20(tokenBits, usdTokenAddress)[0];
            //subtract uniswap 0.30% fees
            //_uniswapFeePercentage is a percentage expressed in 1/10 (a tenth) of a percent hence we divide by 1000
            estFeesInEthPerUnit = estFeesInEthPerUnit.sub(estFeesInEthPerUnit.mul(3).div(1000));

            uint256 feesInEth = feesInUSD.mul(estFeesInEthPerUnit).div(tokenBits);
            return feesInEth;
        }
    }

    /**
     * @dev Checks if token is in free list
     * @param token The address to check
    */
    function isFreeToken(address token)
    public
    view
    returns(bool)
    {
        return listFreeTokens[token];
    }

    function _addERC20Deposit (
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 amountIn,
        uint256 _unlockTime
    ) 
    private 
    returns (uint256 _id){
        _id = ++depositId;
        lockedToken[_id] = Items({
            tokenAddress: _tokenAddress, 
            withdrawalAddress: _withdrawalAddress,
            tokenAmount: amountIn, 
            unlockTime: _unlockTime, 
            withdrawn: false
        });

        allDepositIds.push(_id);
        depositsByWithdrawalAddress[_withdrawalAddress].push(_id);
    }

    function _removeERC20Deposit(
        uint256 _id
    )
    private
    {
        Items storage lockedERC20 = lockedToken[_id];
        //remove entry from lockedToken struct
        lockedERC20.withdrawn = true;
                
        //update balance in address
        walletTokenBalance[lockedERC20.tokenAddress][lockedERC20.withdrawalAddress] = 
        walletTokenBalance[lockedERC20.tokenAddress][lockedERC20.withdrawalAddress].sub(lockedERC20.tokenAmount);
        
        _removeDepositsForWithdrawalAddress(_id, lockedERC20.withdrawalAddress);
    }

    function _removeNFTDeposit(
        uint256 _id
    )
    private
    {
        NFTItems storage lockedNFT = lockedNFTs[_id];
        //remove entry from lockedNFTs struct
        lockedNFT.withdrawn = true;
                
        //update balance in address
        walletTokenBalance[lockedNFT.tokenAddress][lockedNFT.withdrawalAddress] = 
        walletTokenBalance[lockedNFT.tokenAddress][lockedNFT.withdrawalAddress].sub(lockedNFT.tokenAmount);
        
        _removeDepositsForWithdrawalAddress(_id, lockedNFTs[_id].withdrawalAddress);
    }

    function _removeDepositsForWithdrawalAddress(
        uint256 _id,
        address _withdrawalAddress
    )
    private
    {
        //remove this id from this address
        uint256 j;
        uint256 arrLength = depositsByWithdrawalAddress[_withdrawalAddress].length;
        for (j=0; j<arrLength; j++) {
            if (depositsByWithdrawalAddress[_withdrawalAddress][j] == _id) {
                depositsByWithdrawalAddress[_withdrawalAddress][j] = 
                    depositsByWithdrawalAddress[_withdrawalAddress][arrLength - 1];
                depositsByWithdrawalAddress[_withdrawalAddress].pop();
                break;
            }
        }
    }

    function _chargeFees(
        address _tokenAddress
    )
    private
    {
        uint256 minRequiredFeeInEth = getFeesInETH(_tokenAddress);
        if (minRequiredFeeInEth == 0) {
            if (msg.value > 0) {
                (bool refundSuccess,) = _msgSender().call.value(msg.value)("");
                require(refundSuccess, "Refund failed.");
            }
            return;
        }

        bool feesBelowMinRequired = msg.value < minRequiredFeeInEth;
        uint256 feeDiff = feesBelowMinRequired ? 
            SafeMath.sub(minRequiredFeeInEth, msg.value) : 
            SafeMath.sub(msg.value, minRequiredFeeInEth);
            
        if( feesBelowMinRequired ) {
            // multiply by 10000 to convert to Basis Points (BPS)
            uint256 feeSlippagePercentage = feeDiff.mul(10000).div(minRequiredFeeInEth);
            //will allow if diff is less than 5% (500 BPS)
            require(feeSlippagePercentage <= 500, "Fee Not Met");
        }
        (bool success,) = companyWallet.call.value(feesBelowMinRequired ? msg.value : minRequiredFeeInEth)("");
        require(success, "Fee transfer failed");
        /* refund difference. */
        if (!feesBelowMinRequired && feeDiff > 0) {
            (bool refundSuccess,) = _msgSender().call.value(feeDiff)("");
            require(refundSuccess, "Refund failed");
        }
    }

    /**
     * @notice Collects fees from a Uniswap V3 position while maintaining the LP position
     * @dev see https://github.com/Uniswap/v3-periphery/blob/main/contracts/NonfungiblePositionManager.sol#L309
     * @param _id lockTokenId
     */
    function collectUniswapV3LPFees(
        uint256 _id
    ) 
    external 
    {
        NFTItems storage lockedNFT = lockedNFTs[_id];
        
        //check if NFT actually exists
        if(lockedNFT.tokenAddress != address(0x0)) {
            //check if caller is the owner of locked NFT
            require(
                lockedNFT.withdrawalAddress == _msgSender(),
                "Unauthorised to unlock"
            );
            //check if the NFT was already withdrawn
            require(
                !lockedNFT.withdrawn, 
                "NFT: already withdrawn"
            );
        } else {
            revert("No NFT locked");
        }
        uint128 maxAmount = uint128(-1); // type(uint128).max does not work with old compiler
        IUniswapV3NonfungiblePositionManager.CollectParams memory collectFeeParams = 
        IUniswapV3NonfungiblePositionManager.CollectParams({
            tokenId: lockedNFT.tokenId,
            recipient: lockedNFT.withdrawalAddress,
            amount0Max: maxAmount,
            amount1Max: maxAmount
        });

        IUniswapV3NonfungiblePositionManager(
            lockedNFT.tokenAddress
        ).collect(collectFeeParams);
        //Uniswap emits event Collect(params.tokenId, recipient, amount0Collect, amount1Collect);
    }

    function _chargeFeesReferral(
        address _tokenAddress,
        address referrer
    )
    private
    {
        require(_msgSender() != referrer, "Refferer cant be msg sender");

        uint256 feeInEth = getFeesInETH(_tokenAddress);
        if (feeInEth == 0) {
            if (msg.value > 0) {
                (bool refundSuccess,) = _msgSender().call.value(msg.value)("");
                require(refundSuccess, "Refund failed.");
            }
            return;
        }

        uint256 _referralDiscount = referralDiscount;
        require(_referralDiscount > 0, "Refferal discount not set");

        feeInEth = feeInEth.mul(referralDiscount).div(MAX_PERCENTAGE);

        // will allow if diff is less than 5%
        require(msg.value >= feeInEth.mul(95).div(100), "Fee Not Met");

        uint256 takenFee = msg.value < feeInEth ? msg.value : feeInEth;

        uint256 referrerFee = takenFee.mul(referrerCut).div(MAX_PERCENTAGE);
        (bool referrerTransferSuccess,) = payable(referrer).call.value(referrerFee)("");
        require(referrerTransferSuccess, "Referrer transfer failed.");

        // cant overflow because referrerCut must be < MAX_PERCENTAGE -> referrerFee < takenFee
        uint256 trustswapPart = takenFee - referrerFee;
        (bool success,) = companyWallet.call.value(trustswapPart)("");
        require(success, "Fee transfer failed");

        /* refund difference. */
        if (msg.value > takenFee) {
            // cant overflow because takenFee < msg.value
            (bool refundSuccess,) = _msgSender().call.value(msg.value - takenFee)("");
            require(refundSuccess, "Refund failed");
        }

        emit ReferrerRewarded(referrer, referrerFee);
    }

    /**
     */
    function mintNFTforLock(uint256 _id)
        external
        whenNotPaused
        nonReentrant
    {
        require(NFT != address(0), 'NFT: Unintalized');
        require(
            !nftMinted[_id], 
            "NFT already minted"
        );
        NFTItems memory lockedNFT = lockedNFTs[_id];
        Items memory lockedERC20 = lockedToken[_id];

        require(
            (lockedNFT.withdrawalAddress == _msgSender() || lockedERC20.withdrawalAddress == _msgSender()), 
            "Unauthorised"
        );
        require((!lockedNFT.withdrawn && !lockedERC20.withdrawn), 
            "Token/NFT already withdrawn"
        );

        _mintNFTforLock(_id, _msgSender());
    }

    function _mintNFTforLock(
        uint256 _id, 
        address _withdrawalAddress
    ) 
    private{
        require(NFT != address(0), 'NFT: Unintalized');
        nftMinted[_id] = true;
        IERC721Extended(NFT).mintLiquidityLockNFT(_withdrawalAddress, _id);
    }

    /**
     * @dev This function is used to setup a whitelistAdmin with the onlyOwner modifier
     * @param account the account to assign the role to
     * @param access to grank or revoke access
    */

    function updateWhitelistAdminAccess (
        address account,
        bool access
    ) 
    external  
    onlyOwner {
        whitelistAdmins[account] = access;
        emit WhiteListAdminUpdated(account, access);
    }

    function recoverAssets(
        address user, 
        address newRecipient
    ) external onlyOwner {
        
        require(user != address(0), "Invalid user address");
        require(newRecipient != address(0), "Invalid new recipient address");
        require(user != newRecipient, 'User and newRecipient address cannot be the same');

        uint256[] memory userDeposits = depositsByWithdrawalAddress[user];
        require(userDeposits.length > 0, "User has no deposits");
        IERC721Extended _NFT = IERC721Extended(NFT);
        for (uint i = 0; i < userDeposits.length; i++) {
            uint256 _depositId = userDeposits[i];

            Items storage item = lockedToken[_depositId];
            NFTItems storage itemNFT = lockedNFTs[_depositId];

            if (item.tokenAddress != address(0)) {
                address tokenAddress = item.tokenAddress;
                item.withdrawalAddress = newRecipient;
                walletTokenBalance[tokenAddress][newRecipient] = walletTokenBalance[tokenAddress][newRecipient].add(item.tokenAmount);
                walletTokenBalance[tokenAddress][user] = walletTokenBalance[tokenAddress][user].sub(item.tokenAmount);

            } 
            else if (itemNFT.tokenAddress != address(0)) {
                address tokenAddress = itemNFT.tokenAddress;
                itemNFT.withdrawalAddress = newRecipient;
                walletTokenBalance[tokenAddress][newRecipient] = walletTokenBalance[tokenAddress][newRecipient].add(itemNFT.tokenAmount);
                walletTokenBalance[tokenAddress][user] = walletTokenBalance[tokenAddress][user].sub(itemNFT.tokenAmount);
            }
            if(nftMinted[_depositId]) {
                _NFT.burn(_depositId);
                nftMinted[_depositId] = false;
            }
            depositsByWithdrawalAddress[newRecipient].push(_depositId);
        }
        depositsByWithdrawalAddress[user] = new uint256[](0);
    }
}