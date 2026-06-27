/**
 *Submitted for verification at Etherscan.io on 2022-04-18
 */

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol';
import '../interfaces/IPancakePair.sol';
import '../interfaces/IPancakeFactory.sol';
import '../interfaces/IPancakeRouter.sol';
import '../interfaces/IBNBP.sol';
import '../interfaces/IPRC20.sol';
import '../interfaces/IVRFConsumer.sol';
import '../interfaces/IPegSwap.sol';
import '../interfaces/IPotContract.sol';

contract FortuneWheel is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public casinoCount;
    mapping(uint256 => Casino) public tokenIdToCasino;
    mapping(address => bool) public isStable;

    // Info for current round
    BetInfo[] currentBets;
    OutcomeInfo[] public outcomeInfos;
    uint256 public currentBetCount;
    uint256 public roundLiveTime;
    bool public isVRFPending;
    uint256 public requestId;
    uint256 public roundIds;
    uint256 public betIds;

    address public casinoNFTAddress;
    address public BNBPAddress;
    address public consumerAddress;
    address public potAddress;
    address public owner;

    uint256 public maxOutcome;
    uint256 public maxNonceLimit;
    address internal constant wbnbAddr = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // testnet: 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd, mainnet: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    address internal constant busdAddr = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56; // testnet: 0x4608Ea31fA832ce7DCF56d78b5434b49830E91B1, mainnet: 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56
    address internal constant pancakeFactoryAddr = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73; // testnet: 0x6725F303b657a9451d8BA641348b6761A6CC7a17, mainnet: 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
    address internal constant pancakeRouterAddr = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // testnet: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1, mainnet: 0x10ED43C718714eb63d5aA57B78B54704E256024E
    address internal constant coordinatorAddr = 0xc587d9053cd1118f25F645F9E08BB98c9712A4EE; // testnet: 0x6A2AAd07396B36Fe02a22b33cf443582f682c82f, mainnet: 0xc587d9053cd1118f25F645F9E08BB98c9712A4EE
    address internal constant linkTokenAddr = 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD; // testnet: 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06, mainnet: 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD
    address internal constant pegSwapAddr = 0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e;
    address internal constant link677TokenAddr = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;
    uint256 internal constant subscriptionId = 675; // testnet: 2102, mainnet: 675
    uint256 public linkPerBet = 45000000000000000; // 0.045 link token per request
    mapping(uint256 => uint256) public linkSpent;

    struct OutcomeInfo {
        uint256 from;
        uint256 to;
        uint256 outcome;
    }

    struct Casino {
        uint256 nftTokenId;
        address tokenAddress;
        string tokenName;
        uint256 liquidity;
        uint256 roundLiquidity;
        uint256 locked;
        uint256 initialMaxBet;
        uint256 initialMinBet;
        uint256 maxBet;
        uint256 minBet;
        uint256 fee;
        int256 profit;
        uint256 lastSwapTime;
        uint256 roundLimit;
    }

    struct BetInfo {
        uint256 amount;
        address player;
        uint256 tokenId;
        uint256 tokenPrice;
    }

    event FinishedBet(
        uint256 tokenId,
        uint256 betId,
        uint256 roundId,
        address player,
        uint256 nonce,
        uint256 totalAmount,
        uint256 rewardAmount,
        uint256 totalUSD,
        uint256 rewardUSD,
        uint256 maximumReward
    );
    event RoundFinished(uint256 roundId, uint256 nonce, uint256 outcome);
    event TransferFailed(uint256 tokenId, address to, uint256 amount);
    event TokenSwapFailed(uint256 tokenId, uint256 balance, string reason, uint256 timestamp);
    event InitializedBet(uint256 roundId, uint256 tokenId, address player, uint256 amount);
    event AddedLiquidity(uint256 tokenId, address owner, uint256 amount);
    event RemovedLiquidity(uint256 tokenId, address owner, uint256 amount);
    event UpdatedMaxBet(uint256 tokenId, address owner, uint256 value);
    event UpdatedMinBet(uint256 tokenId, address owner, uint256 value);
    event LiquidityChanged(
        uint256 tokenId,
        address changer,
        uint256 liquidity,
        uint256 roundLiquidity,
        uint256 locked,
        bool isFinishedBet
    );
    event SuppliedBNBP(uint256 amount);
    event SuppliedLink(uint256 amount);
    event VRFRequested();

    constructor(
        address nftAddr,
        address _BNBPAddress,
        address _consumerAddress,
        address _potAddress,
        OutcomeInfo[] memory _outcomeInfos
    ) {
        address BNBPPair = IPancakeFactory(pancakeFactoryAddr).getPair(wbnbAddr, _BNBPAddress);
        require(BNBPPair != address(0), 'No liquidity with BNBP and BNB');

        casinoNFTAddress = nftAddr;
        BNBPAddress = _BNBPAddress;
        consumerAddress = _consumerAddress;
        potAddress = _potAddress;
        owner = msg.sender;
        setOutcomeInfos(_outcomeInfos);
    }

    function onlyCasinoOwner(uint256 tokenId) internal view {
        require(IERC721(casinoNFTAddress).ownerOf(tokenId) == msg.sender, 'Not Casino Owner');
    }

    function onlyOwner() internal view {
        require(msg.sender == owner, 'owner');
    }

    /**
     * @dev updates pot contract Address
     */
    function setPotAddress(address addr) external {
        onlyOwner();
        potAddress = addr;
    }

    /**
     * @dev sets token is stable or not
     */
    function setTokenStable(address tokenAddr, bool _isStable) external {
        onlyOwner();
        isStable[tokenAddr] = _isStable;
    }

    /**
     * @dev set how much link token will be consumed per bet
     */
    function setLinkPerBet(uint256 value) external {
        onlyOwner();
        linkPerBet = value;
    }

    /**
     * @dev set outcome infos
     */
    function setOutcomeInfos(OutcomeInfo[] memory _infos) public {
        onlyOwner();
        uint256 max = 0;
        uint256 maxLimit = 0;

        delete outcomeInfos;
        for (uint256 i = 0; i < _infos.length; i++) {
            if (max < _infos[i].outcome) max = _infos[i].outcome;
            if (maxLimit < _infos[i].to) maxLimit = _infos[i].to;
            outcomeInfos.push(_infos[i]);
        }

        maxOutcome = max;
        maxNonceLimit = maxLimit;
    }

    /**
     * @dev returns list of casinos minted
     */
    function getCasinoList()
        external
        view
        returns (Casino[] memory casinos, address[] memory owners, uint256[] memory prices)
    {
        uint256 length = casinoCount;
        casinos = new Casino[](length);
        owners = new address[](length);
        prices = new uint256[](length);
        IERC721 nftContract = IERC721(casinoNFTAddress);

        for (uint256 i = 1; i <= length; ++i) {
            casinos[i - 1] = tokenIdToCasino[i];
            owners[i - 1] = nftContract.ownerOf(casinos[i - 1].nftTokenId);
            if (casinos[i - 1].tokenAddress == address(0)) {
                prices[i - 1] = getBNBPrice();
            } else {
                prices[i - 1] = _getTokenUsdPrice(casinos[i - 1].tokenAddress);
            }
        }
    }

    function getRoundStatus()
        external
        view
        returns (uint256 roundId, BetInfo[] memory betInfos, bool _isVRFPending, uint256 _roundLiveTime)
    {
        roundId = roundIds;
        _isVRFPending = isVRFPending;
        _roundLiveTime = roundLiveTime;
        betInfos = _getCurrentBets();
    }

    /**
     * @dev adds a new casino
     */
    function addCasino(
        uint256 tokenId,
        address[] calldata tokenList,
        string[] calldata tokenNames,
        uint256 maxBet,
        uint256 minBet,
        uint256 fee
    ) external {
        require(msg.sender == casinoNFTAddress || msg.sender == owner, 'Only casino nft contract can call');

        uint256 start = casinoCount;

        for (uint256 i = 0; i < tokenList.length; i++) {
            Casino storage newCasino = tokenIdToCasino[start + i + 1];
            newCasino.tokenAddress = tokenList[i];
            newCasino.tokenName = tokenNames[i];
            newCasino.initialMaxBet = maxBet;
            newCasino.initialMinBet = minBet;
            newCasino.maxBet = maxBet;
            newCasino.minBet = minBet;
            newCasino.fee = fee;
            newCasino.liquidity = 0;
            newCasino.nftTokenId = tokenId;
            newCasino.roundLimit = 100;
            newCasino.roundLiquidity = 0;
        }

        casinoCount += tokenList.length;
    }

    /**
     * @dev set max bet limit for casino
     */
    function setMaxBet(uint256 tokenId, uint256 newMaxBet) external {
        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        onlyCasinoOwner(casinoInfo.nftTokenId);
        require(newMaxBet <= casinoInfo.initialMaxBet, "Can't exceed initial max bet");
        require(newMaxBet >= casinoInfo.minBet, "Can't exceed initial max bet");

        casinoInfo.maxBet = newMaxBet;
        emit UpdatedMaxBet(tokenId, msg.sender, newMaxBet);
    }

    /**
     * @dev set min bet limit for casino
     */
    function setMinBet(uint256 tokenId, uint256 newMinBet) external {
        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        onlyCasinoOwner(casinoInfo.nftTokenId);

        require(newMinBet <= casinoInfo.maxBet, 'min >= max');
        require(newMinBet > casinoInfo.initialMinBet, "Can't be lower than initial min bet");

        casinoInfo.minBet = newMinBet;
        emit UpdatedMinBet(tokenId, msg.sender, newMinBet);
    }

    function _getCurrentBets() internal view returns (BetInfo[] memory) {
        BetInfo[] memory infos;
        if (currentBetCount == 0) return infos;
        infos = new BetInfo[](currentBetCount);

        for (uint256 i = 0; i < currentBetCount; ++i) {
            infos[i] = currentBets[i];
        }
        return infos;
    }

    /**
     * @dev request random number for calculating winner
     */
    function _requestVRF() internal {
        IVRFv2Consumer vrfConsumer = IVRFv2Consumer(consumerAddress);
        uint256 _requestId = vrfConsumer.requestRandomWords();
        requestId = _requestId;
        isVRFPending = true;
        emit VRFRequested();
    }

    /**
     * @dev request nonce if round is finished, start round if the first player has entered
     */
    function _updateRoundStatus() internal {
        if (!isVRFPending && roundLiveTime != 0 && block.timestamp > roundLiveTime + 120) {
            _requestVRF();
        }
        if (currentBetCount == 1) {
            roundLiveTime = block.timestamp;
            roundIds++;
        }
    }

    /**
     * @dev save user bet info to `currentBets`
     */
    function _saveUserBetInfo(uint256 tokenId, uint256 amount, uint256 tokenPrice) internal {
        uint256 count = currentBetCount;

        if (currentBets.length == count) {
            currentBets.push();
        }

        BetInfo storage info = currentBets[count];
        info.tokenId = tokenId;
        info.player = msg.sender;
        info.tokenPrice = tokenPrice;
        info.amount = amount;

        ++currentBetCount;
    }

    /**
     * @dev initialize bet and request nonce to VRF
     *
     * NOTE this function only accepts erc20 tokens
     * @param tokenId tokenId of the Casino
     * @param amount token amount
     */
    function initializeTokenBet(uint256 tokenId, uint256 amount) external nonReentrant {
        require(!isVRFPending, 'VRF Pending');

        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        address tokenAddress = casinoInfo.tokenAddress;
        uint256 liquidity = casinoInfo.liquidity;
        uint256 roundLiquidity = casinoInfo.roundLiquidity;
        require(tokenAddress != address(0), "This casino doesn't support tokens");

        IPRC20 token = IPRC20(tokenAddress);
        IPRC20 busdToken = IPRC20(busdAddr);
        uint256 approvedAmount = token.allowance(msg.sender, address(this));
        uint256 maxReward = amount * maxOutcome;
        uint256 tokenPrice = isStable[tokenAddress] ? 10 ** 18 : _getTokenUsdPrice(tokenAddress);
        uint256 totalUSDValue = (amount * tokenPrice) / 10 ** token.decimals();

        require(token.balanceOf(msg.sender) >= amount, 'Not enough balance');
        require(amount <= approvedAmount, 'Not enough allowance');
        require(maxReward <= roundLiquidity + amount, 'Not enough liquidity');
        require(totalUSDValue <= casinoInfo.maxBet * 10 ** busdToken.decimals(), "Can't exceed max bet limit");
        require(totalUSDValue >= casinoInfo.minBet * 10 ** busdToken.decimals(), "Can't be lower than min bet limit");

        token.transferFrom(msg.sender, address(this), amount);
        liquidity -= (maxReward - amount);
        roundLiquidity -= (maxReward - amount);
        casinoInfo.liquidity = liquidity;
        casinoInfo.roundLiquidity = roundLiquidity;
        casinoInfo.locked += maxReward;

        _saveUserBetInfo(tokenId, amount, tokenPrice);
        _updateRoundStatus();

        emit InitializedBet(roundIds, tokenId, msg.sender, amount);
        emit LiquidityChanged(tokenId, msg.sender, liquidity, roundLiquidity, casinoInfo.locked, false);
    }

    /**
     * @dev initialize bet and request nonce to VRF
     *
     * NOTE this function only accepts bnb
     * @param tokenId tokenId of the Casino
     * @param amount eth amount
     */
    function initializeEthBet(uint256 tokenId, uint256 amount) external payable {
        require(!isVRFPending, 'VRF Pending');

        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        uint256 liquidity = casinoInfo.liquidity;
        uint256 roundLiquidity = casinoInfo.roundLiquidity;
        require(casinoInfo.tokenAddress == address(0), 'This casino only support bnb');

        IPRC20 busdToken = IPRC20(busdAddr);
        uint256 maxReward = amount * maxOutcome;
        uint256 bnbPrice = getBNBPrice();
        uint256 totalUSDValue = (bnbPrice * amount) / 10 ** 18;

        require(msg.value == amount, 'Not correct bet amount');
        require(maxReward <= roundLiquidity + amount, 'Not enough liquidity');
        require(totalUSDValue <= casinoInfo.maxBet * 10 ** busdToken.decimals(), "Can't exceed max bet limit");
        require(totalUSDValue >= casinoInfo.minBet * 10 ** busdToken.decimals(), "Can't be lower than min bet limit");

        liquidity -= (maxReward - amount);
        roundLiquidity -= (maxReward - amount);
        casinoInfo.liquidity = liquidity;
        casinoInfo.roundLiquidity = roundLiquidity;
        casinoInfo.locked += maxReward;

        _saveUserBetInfo(tokenId, amount, bnbPrice);
        _updateRoundStatus();

        emit InitializedBet(roundIds, tokenId, msg.sender, amount);
        emit LiquidityChanged(tokenId, msg.sender, liquidity, roundLiquidity, casinoInfo.locked, false);
    }

    /**
     * @dev request nonce when round time is over
     */
    function requestNonce() external {
        require(!isVRFPending && roundLiveTime != 0 && block.timestamp > roundLiveTime + 120, 'Round not ended');
        _requestVRF();
    }

    function isVRFFulfilled() public view returns (bool) {
        (bool fulfilled, uint256[] memory nonces) = IVRFv2Consumer(consumerAddress).getRequestStatus(requestId);
        return fulfilled;
    }

    /**
     * @dev returns outcome X from the given nonce
     */
    function _spinWheel(uint256 nonce) private view returns (uint256 outcome) {
        uint256 length = outcomeInfos.length;
        for (uint256 i = 0; i < length; i++) {
            if (nonce >= outcomeInfos[i].from && nonce <= outcomeInfos[i].to) {
                return outcomeInfos[i].outcome;
            }
        }
    }

    /**
     * @dev retrieve nonce and spin the wheel, return reward if user wins
     *
     */
    function finishRound() external nonReentrant {
        require(isVRFPending == true, 'VRF not requested');

        (bool fulfilled, uint256[] memory nonces) = IVRFv2Consumer(consumerAddress).getRequestStatus(requestId);
        require(fulfilled == true, 'not yet fulfilled');

        uint256 nonce = nonces[0] % (maxNonceLimit + 1);
        uint256 outcome = _spinWheel(nonce);
        uint256 length = currentBetCount;
        uint256 linkPerRound = linkPerBet;
        uint256 i;

        for (i = 0; i < length; ++i) {
            BetInfo memory info = currentBets[i];
            linkSpent[info.tokenId] += (linkPerRound / length);
            _finishUserBet(info, outcome);
        }

        isVRFPending = false;
        delete roundLiveTime;
        delete currentBetCount;
        emit RoundFinished(roundIds, nonce, outcome);
    }

    /**
     * @dev finish individual user's pending bet based on the nonce retreived
     */
    function _finishUserBet(BetInfo memory info, uint256 outcome) internal {
        Casino storage casinoInfo = tokenIdToCasino[info.tokenId];
        uint256 decimal = casinoInfo.tokenAddress == address(0) ? 18 : IPRC20(casinoInfo.tokenAddress).decimals();
        uint256 totalReward = info.amount * outcome;
        uint256 maxReward = info.amount * maxOutcome;
        uint256 totalUSDValue = (info.amount * info.tokenPrice) / 10 ** decimal;
        uint256 totalRewardUSD = (totalReward * info.tokenPrice) / 10 ** decimal;

        betIds++;
        if (totalReward > 0) {
            if (casinoInfo.tokenAddress != address(0)) {
                IPRC20(casinoInfo.tokenAddress).transfer(info.player, totalReward);
            } else {
                bool sent = payable(info.player).send(totalReward);
                require(sent, 'send fail');
            }
        }
        casinoInfo.liquidity += maxReward - totalReward;
        casinoInfo.roundLiquidity += maxReward - totalReward;
        casinoInfo.locked -= maxReward;
        casinoInfo.profit = casinoInfo.profit + int256(info.amount) - int256(totalReward);

        emit FinishedBet(
            info.tokenId,
            betIds,
            roundIds,
            info.player,
            outcome,
            info.amount,
            totalReward,
            totalUSDValue,
            totalRewardUSD,
            maxReward
        );
    }

    /**
     * @dev adds liquidity to the casino pool
     * NOTE this is only for casinos that uses tokens
     */
    function addLiquidityWithTokens(uint256 tokenId, uint256 amount) external {
        onlyCasinoOwner(tokenId);

        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        require(casinoInfo.tokenAddress != address(0), "This casino doesn't support tokens");

        IERC20 token = IERC20(casinoInfo.tokenAddress);
        token.safeTransferFrom(msg.sender, address(this), amount);
        casinoInfo.liquidity += amount;
        casinoInfo.roundLiquidity += (amount * casinoInfo.roundLimit) / 100;
        emit AddedLiquidity(tokenId, msg.sender, amount);
        emit LiquidityChanged(
            tokenId,
            msg.sender,
            casinoInfo.liquidity,
            casinoInfo.roundLiquidity,
            casinoInfo.locked,
            false
        );
    }

    /**
     * @dev adds liquidity to the casino pool
     * NOTE this is only for casinos that uses bnb
     */
    function addLiquidityWithEth(uint256 tokenId) external payable {
        onlyCasinoOwner(tokenId);

        Casino storage casinoInfo = tokenIdToCasino[tokenId];

        require(casinoInfo.tokenAddress == address(0), "This casino doesn't supports bnb");
        casinoInfo.liquidity += msg.value;
        casinoInfo.roundLiquidity += (msg.value * casinoInfo.roundLimit) / 100;
        emit AddedLiquidity(tokenId, msg.sender, msg.value);
        emit LiquidityChanged(
            tokenId,
            msg.sender,
            casinoInfo.liquidity,
            casinoInfo.roundLiquidity,
            casinoInfo.locked,
            false
        );
    }

    /**
     * @dev removes liquidity from the casino pool
     */
    function removeLiquidity(uint256 tokenId, uint256 amount) external {
        onlyCasinoOwner(tokenId);

        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        uint256 liquidity = casinoInfo.liquidity;

        require(int256(liquidity - amount) >= casinoInfo.profit, 'Cannot withdraw profit before it is fee taken');
        require(liquidity >= amount, 'Not enough liquidity');

        unchecked {
            casinoInfo.liquidity -= amount;
            casinoInfo.roundLiquidity -= (amount * casinoInfo.roundLimit) / 100;
        }

        if (casinoInfo.tokenAddress != address(0)) {
            IERC20 token = IERC20(casinoInfo.tokenAddress);
            token.safeTransfer(msg.sender, amount);
        } else {
            bool sent = payable(msg.sender).send(amount);
            require(sent, 'Failed Transfer');
        }
        emit RemovedLiquidity(tokenId, msg.sender, amount);
        emit LiquidityChanged(
            tokenId,
            msg.sender,
            casinoInfo.liquidity,
            casinoInfo.roundLiquidity,
            casinoInfo.locked,
            false
        );
    }

    function updateRoundLimit(uint256 tokenId, uint256 value) external {
        onlyCasinoOwner(tokenId);
        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        Casino memory info = tokenIdToCasino[tokenId];
        unchecked {
            if (value > info.roundLimit) {
                casinoInfo.roundLiquidity += (info.liquidity * (value - info.roundLimit)) / 100;
            } else {
                casinoInfo.roundLiquidity -= (info.liquidity * (info.roundLimit - value)) / 100;
            }
        }
        casinoInfo.roundLimit = value;
        emit LiquidityChanged(tokenId, msg.sender, info.liquidity, casinoInfo.roundLiquidity, info.locked, false);
    }

    /**
     * @dev update casino's current profit and liquidity.
     */
    function _updateProfitInfo(uint256 tokenId, uint256 fee, uint256 calculatedProfit) internal {
        if (fee == 0) return;
        Casino storage casinoInfo = tokenIdToCasino[tokenId];
        casinoInfo.liquidity -= fee;
        casinoInfo.profit -= int256(calculatedProfit);
        casinoInfo.lastSwapTime = block.timestamp;
    }

    /**
     * @dev update casino's link consumption info
     */
    function _updateLinkConsumptionInfo(uint256 tokenId, uint256 tokenAmount) internal {
        uint256 linkOut = getLinkAmountForToken(tokenIdToCasino[tokenId].tokenAddress, tokenAmount);
        if (linkOut >= linkSpent[tokenId]) linkSpent[tokenId] = 0;
        else linkSpent[tokenId] -= linkOut;
    }

    /**
     * @dev get usd price of a token by usdt
     */
    function _getTokenUsdPrice(address tokenAddress) internal view returns (uint256) {
        if (isStable[tokenAddress]) return 10 ** 18;

        IPancakeRouter02 router = IPancakeRouter02(pancakeRouterAddr);
        IPRC20 token = IPRC20(tokenAddress);

        address[] memory path = new address[](3);
        path[0] = tokenAddress;
        path[1] = wbnbAddr;
        path[2] = busdAddr;
        uint256 usdValue = router.getAmountsOut(10 ** token.decimals(), path)[2];

        return usdValue;
    }

    /**
     * @dev Gets current pulse price in comparison with BNB and USDT
     */
    function getBNBPrice() public view returns (uint256 price) {
        IPancakeRouter02 router = IPancakeRouter02(pancakeRouterAddr);
        address[] memory path = new address[](2);
        path[0] = wbnbAddr;
        path[1] = busdAddr;
        uint256[] memory amounts = router.getAmountsOut(10 ** 18, path);
        return amounts[1];
    }

    /**
     * @dev returns token amount needed for `linkAmount` when swapping given token into link
     */
    function getTokenAmountForLink(address tokenAddr, uint256 linkAmount) public view returns (uint256) {
        IPancakeRouter02 router = IPancakeRouter02(pancakeRouterAddr);
        address[] memory path;
        if (tokenAddr == address(0) || tokenAddr == wbnbAddr) {
            path = new address[](2);
            path[0] = wbnbAddr;
            path[1] = linkTokenAddr;
        } else {
            path = new address[](3);
            path[0] = tokenAddr;
            path[1] = wbnbAddr;
            path[2] = linkTokenAddr;
        }

        return router.getAmountsIn(linkAmount, path)[0];
    }

    /**
     * @dev returns link token amount out when swapping given token into link
     */
    function getLinkAmountForToken(address tokenAddr, uint256 tokenAmount) public view returns (uint256) {
        IPancakeRouter02 router = IPancakeRouter02(pancakeRouterAddr);
        address[] memory path;
        bool isBNB = tokenAddr == address(0) || tokenAddr == wbnbAddr;
        if (isBNB) {
            path = new address[](2);
            path[0] = wbnbAddr;
            path[1] = linkTokenAddr;
        } else {
            path = new address[](3);
            path[0] = tokenAddr;
            path[1] = wbnbAddr;
            path[2] = linkTokenAddr;
        }

        return router.getAmountsOut(tokenAmount, path)[isBNB ? 1 : 2];
    }

    /**
     * @dev resets round and return all money back to players
     */
    function resetRound() external nonReentrant {
        onlyOwner();
        require(roundLiveTime != 0, 'empty');

        uint256 length = currentBetCount;
        for (uint256 i = 0; i < length; ++i) {
            BetInfo memory info = currentBets[i];
            Casino storage casinoInfo = tokenIdToCasino[info.tokenId];
            uint256 maximumReward = info.amount * maxOutcome;

            casinoInfo.locked -= maximumReward;
            casinoInfo.liquidity += (maximumReward - info.amount);
            casinoInfo.roundLiquidity = (casinoInfo.liquidity * casinoInfo.roundLimit) / 100;

            // Transfer money back
            address tokenAddress = casinoInfo.tokenAddress;
            if (tokenAddress != address(0)) {
                IPRC20(tokenAddress).transfer(info.player, info.amount);
            } else {
                bool sent = payable(info.player).send(info.amount);
                require(sent, 'send fail');
            }
        }
        delete isVRFPending;
        delete currentBetCount;
        delete roundLiveTime;
    }

    /**
     * @dev swaps profit fees of casinos into BNBP
     */
    function swapProfitFees() external {
        IPancakeRouter02 router = IPancakeRouter02(pancakeRouterAddr);
        address[] memory path = new address[](2);
        uint256 totalBNBForGame;
        uint256 totalBNBForLink;
        uint256 length = casinoCount;
        uint256 BNBPPool = 0;

        // Swap each token to BNB
        for (uint256 i = 1; i <= length; ++i) {
            Casino memory casinoInfo = tokenIdToCasino[i];
            IERC20 token = IERC20(casinoInfo.tokenAddress);

            if (casinoInfo.liquidity == 0) continue;

            uint256 availableProfit = casinoInfo.profit < 0 ? 0 : uint256(casinoInfo.profit);
            if (casinoInfo.liquidity < availableProfit) {
                availableProfit = casinoInfo.liquidity;
            }

            uint256 gameFee = (availableProfit * casinoInfo.fee) / 100;
            uint256 amountForLinkFee = getTokenAmountForLink(casinoInfo.tokenAddress, linkSpent[i]);
            _updateProfitInfo(i, uint256(gameFee), availableProfit);
            casinoInfo.liquidity = tokenIdToCasino[i].liquidity;

            // If fee from the profit is not enought for link, then use liquidity
            if (gameFee < amountForLinkFee) {
                if (casinoInfo.liquidity < (amountForLinkFee - gameFee)) {
                    amountForLinkFee = gameFee + casinoInfo.liquidity;
                    tokenIdToCasino[i].liquidity = 0;
                } else {
                    tokenIdToCasino[i].liquidity -= (amountForLinkFee - gameFee);
                }
                gameFee = 0;
            } else {
                gameFee -= amountForLinkFee;
            }

            // Update Link consumption info
            _updateLinkConsumptionInfo(i, amountForLinkFee);

            if (casinoInfo.tokenAddress == address(0)) {
                totalBNBForGame += gameFee;
                totalBNBForLink += amountForLinkFee;
                continue;
            }
            if (casinoInfo.tokenAddress == BNBPAddress) {
                BNBPPool += gameFee;
                gameFee = 0;
            }

            path[0] = casinoInfo.tokenAddress;
            path[1] = wbnbAddr;

            if (gameFee + amountForLinkFee == 0) {
                continue;
            }
            token.approve(address(router), gameFee + amountForLinkFee);
            uint256[] memory swappedAmounts = router.swapExactTokensForETH(
                gameFee + amountForLinkFee,
                0,
                path,
                address(this),
                block.timestamp
            );
            totalBNBForGame += (swappedAmounts[1] * gameFee) / (gameFee + amountForLinkFee);
            totalBNBForLink += (swappedAmounts[1] * amountForLinkFee) / (gameFee + amountForLinkFee);
        }

        path[0] = wbnbAddr;
        // Convert to LINK
        if (totalBNBForLink > 0) {
            path[1] = linkTokenAddr;

            // Swap BNB into Link Token
            uint256 linkAmount = router.swapExactETHForTokens{ value: totalBNBForLink }(
                0,
                path,
                address(this),
                block.timestamp
            )[1];

            // Convert Link to ERC677 Link
            IERC20(linkTokenAddr).approve(pegSwapAddr, linkAmount);
            PegSwap(pegSwapAddr).swap(linkAmount, linkTokenAddr, link677TokenAddr);

            // Fund VRF subscription account
            LinkTokenInterface(link677TokenAddr).transferAndCall(
                coordinatorAddr,
                linkAmount,
                abi.encode(subscriptionId)
            );
            emit SuppliedLink(linkAmount);
        }

        // Swap the rest of BNB to BNBP
        if (totalBNBForGame > 0) {
            path[1] = BNBPAddress;
            BNBPPool += router.swapExactETHForTokens{ value: totalBNBForGame }(0, path, address(this), block.timestamp)[
                1
            ];
        }

        if (BNBPPool > 0) {
            // add BNBP to tokenomics pool
            IERC20(BNBPAddress).approve(potAddress, BNBPPool);
            IPotLottery(potAddress).addAdminTokenValue(BNBPPool);

            emit SuppliedBNBP(BNBPPool);
        }
    }

    receive() external payable {}
}
