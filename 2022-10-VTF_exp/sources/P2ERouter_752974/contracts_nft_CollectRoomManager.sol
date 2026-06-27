// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../libraries/TransferHelper.sol';
import '../interfaces/IP2EERC1155.sol';
import '../interfaces/IInvite.sol';
import '../interfaces/IWETH.sol';
import '../core/SafeOwnable.sol';
import '../core/Random.sol';
import 'hardhat/console.sol';


contract CollectRoomManager is SafeOwnable, Random {
    using SafeMath for uint256;
    using Strings for uint256;
    using SafeERC20 for IERC20;

    event NewCollectRoom(uint rid, IERC20 rewardToken, uint rewardAmount, uint startSeconds, uint endSeconds);
    event RoomValue(uint rid, IERC20 valueToken, uint valueAmount);
    event RoomRange(uint rid, uint nftType, uint nftID, uint startIndex, uint endIndex);
    event NFTCreated(IP2EERC1155 nftToken, uint rid, uint[] ids, uint[] types, uint[] values);
    event BuyBlindBox(uint rid, address user, IERC20 token, uint num, uint payAmount, uint payFee, bytes32 requestId);
    event OpenBlindBox(uint rid, address to, uint rangeIndex, uint num, bytes32 requestId);
    event Claim(uint rid, address to, uint num, uint reward);
    event NewMaxOpenNum(uint256 oldMaxOpenNum, uint256 newMaxOpenNum);
    event RewardPoolDeposit(uint rid, address from, IERC20 token, uint256 amount);
    event RewardPoolWithdraw(uint rid, address to, IERC20 token, uint256 amount);

    event NewTokenReceiver(address oldReceiver, address newReceiver);
    event NewFeeReceiver(address oldReceiver, address newReceiver);
    event NewRewardReceiver(address oldReceiver, address newReceiver);
    event TokenWithdraw(IERC20 token, uint amount);
    event FeeWithdraw(IERC20 token, uint amount);
    event RewardWithdraw(uint rid, IERC20 token, uint amount);

    uint256 constant MAX_END_INDEX = 1000000;
    uint256 constant VALUE_FEE_BASE = 10000;
    address immutable WETH;
    uint256 constant MAX_INVITE_HEIGHT = 3;
    function getInvitePercent(uint height) internal pure returns (uint) {
        if (height == 0) {
            return 2000;
        } else if (height == 1) {
            return 1000;
        } else if (height == 2) {
            return 500;
        } else {
            return 0;
        }
    }
    uint256 constant PERCENT_BASE = 10000;

    struct RoomInfo {
        IERC20 rewardToken;
        uint256 rewardAmount;
        uint256 startSeconds;
        uint256 endSeconds;
        uint256 rewardPool;
        uint256 valueFee;
        uint256 maxOpenNum;
    }

    struct RangeInfo {
        uint256 nftType;
        uint256 nftId;
        uint256 startIndex;
        uint256 endIndex;
    }

    struct RandomInfo {
        address to;
        uint256 rid;
        uint256 num;
    }

    RoomInfo[] public roomInfo;
    mapping(uint256 => IERC20[]) public valueTokenList;
    mapping(uint256 => mapping(IERC20 => bool)) public valueTokens;
    mapping(uint256 => mapping(IERC20 => uint256)) public valueAmount;
    mapping(uint256 => RangeInfo[]) public rangeInfo;
    IInvite public invite;
    IP2EERC1155 public nftToken;

    address public tokenReceiver;
    address public feeReceiver;
    address public rewardReceiver;
    mapping(IERC20 => uint) public totalTokenAmount;
    mapping(IERC20 => uint) public totalFeeAmount;

    mapping(bytes32 => RandomInfo) public randomInfo;
    mapping(uint256 => mapping(address => uint256)) public blindBoxNum;

    function setTokenReceiver(address _tokenReceiver) external onlyOwner {
        require(_tokenReceiver != address(0), "tokenReceiver is zero");
        emit NewTokenReceiver(tokenReceiver, _tokenReceiver);
        tokenReceiver = _tokenReceiver;
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        require(_feeReceiver != address(0), "tokenReceiver is zero");
        emit NewFeeReceiver(feeReceiver, _feeReceiver);
        feeReceiver = _feeReceiver;
    }

    function setRewardReceiver(address _rewardReceiver) external onlyOwner {
        require(_rewardReceiver != address(0), "tokenReceiver is zero");
        emit NewRewardReceiver(_rewardReceiver, rewardReceiver);
        rewardReceiver = _rewardReceiver;
    }

    function tokenTransfer(IERC20 _token, address _to, uint _amount) internal returns (uint) {
        if (_amount == 0) {
            return 0;
        }
        if (address(_token) == WETH) {
            IWETH(address(_token)).withdraw(_amount);
            TransferHelper.safeTransferETH(_to, _amount);
        } else {
            _token.safeTransfer(_to, _amount);
        }
        return _amount;
    }

    function tokenWithdraw(IERC20 _token, uint _amount) external onlyOwner {
        if (_amount > totalTokenAmount[_token]) {
            _amount = totalTokenAmount[_token];
        }
        totalTokenAmount[_token] = totalTokenAmount[_token].sub(_amount);
        require(tokenReceiver != address(0), "tokenReceiver is zero");
        tokenTransfer(_token, tokenReceiver, _amount);
        emit TokenWithdraw(_token, _amount);
    }

    function feeWithdraw(IERC20 _token, uint _amount) external onlyOwner {
        if (_amount > totalFeeAmount[_token]) {
            _amount = totalFeeAmount[_token];
        }
        totalFeeAmount[_token] = totalFeeAmount[_token].sub(_amount);
        require(feeReceiver != address(0), "feeReceiver is zero");
        tokenTransfer(_token, feeReceiver, _amount);
        emit FeeWithdraw(_token, _amount);
    }

    function roomInfoLength() external view returns (uint256) {
        return roomInfo.length;
    }

    function valueInfoLength(uint256 rid) external view returns (uint256) {
        return valueTokenList[rid].length;
    }

    function rangeInfoLength(uint256 rid) external view returns (uint256) {
        return rangeInfo[rid].length;
    }

    function setMaxOpenNum(uint rid, uint256 newOpenNum) external onlyOwner {
        require(rid < roomInfo.length, "illegal rid");
        emit NewMaxOpenNum(roomInfo[rid].maxOpenNum, newOpenNum);
        roomInfo[rid].maxOpenNum = newOpenNum;
    }

    function setRoomTime(uint rid, uint _startSeconds, uint _endSeconds) external RoomNotBegin(rid) {
        require(msg.sender == owner(), "Caller not owner");
        require(_endSeconds > _startSeconds, "illegal time");
        roomInfo[rid].startSeconds = _startSeconds;
        roomInfo[rid].endSeconds = _endSeconds;
    }

    constructor(address _WETH, IInvite _invite, IP2EERC1155 _nftToken, address _tokenReceiver, address _feeReceiver, address _rewardReceiver, address _linkAccessor) Random(_linkAccessor) SafeOwnable(msg.sender) {
        require(_WETH != address(0), "WETH is zero");
        WETH = _WETH;
        require(address(_invite) != address(0), "invite address is zero");
        invite = _invite;
        require(address(_nftToken) != address(0), "nftToken is zero");
        nftToken = _nftToken;
        require(_tokenReceiver != address(0), "receiver is zero");
        tokenReceiver = _tokenReceiver;
        emit NewTokenReceiver(address(0), tokenReceiver);
        require(_feeReceiver != address(0), "fee reciever is zero");
        feeReceiver = _feeReceiver;
        emit NewFeeReceiver(address(0), feeReceiver);
        require(_rewardReceiver != address(0), "rewardReceiver is zero");
        rewardReceiver = _rewardReceiver;
        emit NewRewardReceiver(address(0), rewardReceiver);
    }

    modifier RoomNotBegin(uint rid) {
        require(rid < roomInfo.length, "illegal rid");
        require(block.timestamp < roomInfo[rid].startSeconds || block.timestamp > roomInfo[rid].endSeconds, "Room Already Begin");
        _;
    }

    modifier RoomBegin(uint rid) {
        require(block.timestamp >= roomInfo[rid].startSeconds && block.timestamp <= roomInfo[rid].endSeconds, "Room Already Finish");
        _;
    }

    function add(
        IERC20 _rewardToken, uint256 _rewardAmount, uint256 _startSeconds, uint256 _endSeconds, uint256 _valueFee, 
        IERC20[] memory _tokens, uint256[] memory _amounts, uint256[] memory _nftTypes, uint256[] memory _nftValues, uint256[] memory _nftPercents
    ) external onlyOwner {
        require(address(_rewardToken) != address(0), "rewardToken is zero address");
        require(_endSeconds > _startSeconds, "illegal time");
        roomInfo.push(RoomInfo({
            rewardToken: _rewardToken,
            rewardAmount: _rewardAmount,
            startSeconds: _startSeconds,
            endSeconds: _endSeconds,
            rewardPool: 0,
            valueFee: _valueFee,
            maxOpenNum: 5
        }));
        uint rid = roomInfo.length - 1;
        emit NewCollectRoom(rid, _rewardToken, _rewardAmount, _startSeconds, _endSeconds);
        require(_nftTypes.length == _nftPercents.length && _nftTypes.length > 0, "illegal type percent info");
        uint lastEndIndex = 0;
        for (uint i = 0; i < rangeInfo[rid].length; i ++) {
            lastEndIndex = rangeInfo[rid][i].endIndex;
        }
        uint[] memory nftIDs = nftToken.createBatchDefault(_nftTypes, _nftValues);
        emit NFTCreated(nftToken, rid, nftIDs, _nftTypes, _nftValues);
        for (uint i = 0; i < _nftTypes.length; i ++) {
            rangeInfo[rid].push(RangeInfo({
                nftType : _nftTypes[i],
                startIndex: lastEndIndex,
                endIndex: lastEndIndex.add(_nftPercents[i]),
                nftId: nftIDs[i]
            }));
            lastEndIndex = lastEndIndex.add(_nftPercents[i]);
        }
        require(lastEndIndex == MAX_END_INDEX, "illegal percent info");
        require(_tokens.length == _amounts.length && _tokens.length > 0, "illegal token amount info");
        for (uint i = 0; i < _tokens.length; i ++) {
            require(address(_tokens[i]) != address(0), "token address is zero");
            require(_amounts[i] > 0, "illegal amount value");
            require(!valueTokens[rid][_tokens[i]], "token already exists");
            valueTokens[rid][_tokens[i]] = true;
            valueTokenList[rid].push(_tokens[i]);
            valueAmount[rid][_tokens[i]] = _amounts[i];
            emit RoomValue(rid, _tokens[i], _amounts[i]);
        }
    }

    function doRandom() internal returns (bytes32){
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, tx.origin, block.coinbase, block.number)));
        bytes32 requestId = _requestRandom(seed);
        require(randomInfo[requestId].to == address(0), "random already exists");
        return requestId;
    }

    function buyBlindBox(uint256 _rid, IERC20 _token, uint256 _num, address _to) external payable {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_num <= roomInfo[_rid].maxOpenNum, "illegal open num");
        require(block.timestamp >= room.startSeconds && block.timestamp <= room.endSeconds, "room not begin or already finish");
        require(valueTokens[_rid][_token], "token not support");
        uint payAmount = valueAmount[_rid][_token].mul(_num);
        uint payFee = payAmount.mul(room.valueFee).div(VALUE_FEE_BASE);

        address[] memory inviters = invite.inviterTree(_to, MAX_INVITE_HEIGHT);
        uint[] memory amounts = new uint[](inviters.length);
        uint totalInviterAmount = 0;
        for (uint i = 0; i < inviters.length; i ++) {
            uint percent = getInvitePercent(i);
            amounts[i] = payAmount.mul(percent).div(PERCENT_BASE);
            totalInviterAmount = totalInviterAmount.add(amounts[i]);
        }
        if (address(_token) == WETH) {
            require(msg.value == payAmount.add(payFee), "illegal ETH amount");
            IWETH(WETH).deposit{value: payAmount.add(payFee)}();
        } else {
            SafeERC20.safeTransferFrom(_token, msg.sender, address(this), payAmount.add(payFee));
        }
        _token.safeTransfer(address(invite), totalInviterAmount);
        uint remainAmount = invite.sendReward(_to, _token, amounts);
        payAmount = payAmount.sub(totalInviterAmount.sub(remainAmount));
        totalTokenAmount[_token] = totalTokenAmount[_token].add(payAmount);
        totalFeeAmount[_token] = totalFeeAmount[_token].add(payFee);

        bytes32 requestId = doRandom();
        randomInfo[requestId] = RandomInfo({
            to: _to,
            rid: _rid,
            num: _num
        });
        blindBoxNum[_rid][_to] = blindBoxNum[_rid][_to].add(_num);

        emit BuyBlindBox(_rid, _to, _token, _num, payAmount.add(totalInviterAmount.sub(remainAmount)), payFee, requestId);
    }

    function finishRandom(bytes32 _requestId) internal override {
        RandomInfo storage random = randomInfo[_requestId];
        require(random.to != address(0), "requestId not exists");
        uint seed = randomResult[_requestId];
        for (uint i = 0; i < random.num; i ++) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint nftRange = seed.mod(MAX_END_INDEX);
            uint rangeIndex = 0;
            for (; rangeIndex < rangeInfo[random.rid].length; rangeIndex ++) {
                if (nftRange >= rangeInfo[random.rid][rangeIndex].startIndex && nftRange < rangeInfo[random.rid][rangeIndex].endIndex) {
                    RangeInfo storage range = rangeInfo[random.rid][rangeIndex]; 
                    nftToken.mint(random.to, range.nftId, 1, "0x");
                    emit OpenBlindBox(random.rid, random.to, rangeIndex, 1, _requestId);
                    break;
                }
            }
            require(rangeIndex < rangeInfo[random.rid].length, "rangeInfo error");
        }
        blindBoxNum[random.rid][random.to] = blindBoxNum[random.rid][random.to].sub(random.num);
        delete randomInfo[_requestId];

        super.finishRandom(_requestId);
    }

    function claim(uint256 rid, address to) external {
        require(rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[rid];
        uint256 nftNum = rangeInfo[rid].length;
        address[] memory accounts = new address[](nftNum);
        uint256[] memory ids = new uint256[](nftNum);
        for (uint i = 0; i < nftNum; i ++) {
            accounts[i] = to; 
            ids[i] = rangeInfo[rid][i].nftId;
        }
        uint256[] memory balances = nftToken.balanceOfBatch(accounts, ids);
        uint minNum = uint(-1);
        for (uint i = 0; i < balances.length; i ++) {
            if (balances[i] < minNum) {
                minNum = balances[i];
            }
        }
        if (minNum <= 0) {
            return; 
        }
        uint reward = room.rewardAmount.mul(minNum);
        require(room.rewardPool >= reward, "reward pool not enough");
        room.rewardPool = room.rewardPool.sub(reward);
        for (uint i = 0; i < balances.length; i ++) {
            balances[i] = minNum;
        }
        nftToken.burnBatch(to, ids, balances);
        SafeERC20.safeTransfer(room.rewardToken, to, reward);
        emit Claim(rid, to, minNum, reward);
    }

    function roomDeposit(uint rid, uint amount) external {
        require(rid < roomInfo.length, "rid not exist");  
        RoomInfo storage room = roomInfo[rid];
        uint balanceBefore = room.rewardToken.balanceOf(address(this));
        SafeERC20.safeTransferFrom(room.rewardToken, msg.sender, address(this), amount);
        uint balanceAfter = room.rewardToken.balanceOf(address(this));
        require(balanceAfter > balanceBefore, "token transfer error");
        room.rewardPool = room.rewardPool.add(balanceAfter.sub(balanceBefore));
        emit RewardPoolDeposit(rid, msg.sender, room.rewardToken, balanceAfter.sub(balanceBefore));
    }

    function roomWithdraw(uint rid, uint amount) external RoomNotBegin(rid) {
        require(msg.sender == owner(), "Caller not owner");
        RoomInfo storage room = roomInfo[rid];
        if (block.timestamp > room.endSeconds) {
            require(block.timestamp > room.endSeconds.add(60 * 60 * 24 * 7), "the reward can be withdrawed only after 1 week");
        }
        if (room.rewardPool < amount) {
            amount = room.rewardPool;
        }
        room.rewardPool = room.rewardPool.sub(amount);
        tokenTransfer(room.rewardToken, rewardReceiver, amount);
        emit RewardPoolWithdraw(rid, rewardReceiver, room.rewardToken, amount);
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }
}
