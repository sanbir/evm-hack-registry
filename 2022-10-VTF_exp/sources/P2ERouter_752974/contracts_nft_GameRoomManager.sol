// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../interfaces/IP2EERC1155.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';
import '../core/Random.sol';
import '../interfaces/IInvite.sol';

contract GameRoomManager is SafeOwnable, Random {
    using SafeMath for uint256;
    using Strings for uint256;

    event NewGameRoom(uint rid, IERC20 token, uint value, uint valueFee, uint odds);
    event RoomRange(uint rid, uint nftType, uint startIndex, uint endIndex);
    event BuyBlindBox(uint rid, address user, uint256 loop, uint num, uint payAmount, uint payFee, bytes32 requestId);
    event OpenBlindBox(uint rid, uint loop, address to, uint rangeIndex, bytes32 requestId);
    event Claim(uint rid, uint loop, address to, uint num, uint reward);
    event RewardPoolDeposit(uint rid, address from, IERC20 token, uint256 amount);
    event RewardPoolWithdraw(uint rid, address to, IERC20 token, uint256 amount);
    event NewReceiver(address oldReceiver, address newReceiver);
    event NewRewardReceiver(address oldRewardReceiver, address newRewardReceiver);
    event NewMaxOpenNum(uint256 oldMaxOpenNum, uint256 newMaxOpenNum);

    uint256 constant MAX_END_INDEX = 1000000;
    uint256 constant VALUE_FEE_BASE = 10000;
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
        IERC20 token;
        uint256 value;
        uint256 currentLoop;
        uint256 loopBeginAt;
        uint256 loopFinishAt;
        uint256 loopInterval;
        bool loopFinish;
        uint256 valueFee;
        uint256 rewardAmount;
        uint256 odds;
        uint256 maxOpenNum;
    }

    struct RangeInfo {
        uint256 nftType;
        uint256 startIndex;
        uint256 endIndex;
    }

    struct RandomInfo {
        address to;
        uint256 rid;
        uint256 num;
        uint256 loop;
    }

    RoomInfo[] public roomInfo;
    mapping(uint256 => RangeInfo[]) public rangeInfo;
    mapping(bytes32 => RandomInfo) public randomInfo;
    mapping(uint256 => uint256[]) nftTypes;
    mapping(uint256 => mapping(uint256 => uint256[])) public nftIDs;
    mapping(uint256 => mapping(uint256 => uint256)) public loopResult;
    mapping(uint256 => mapping(address => uint256)) public blindBoxNum;

    IInvite public invite;
    IP2EERC1155 public nftToken;
    address public receiver;
    address public rewardReceiver;

    function roomInfoLength() external view returns (uint256) {
        return roomInfo.length;
    }

    function loopNFT(uint _rid, uint _loop) external view returns (uint256[] memory) {
        return nftIDs[_rid][_loop];
    }
    
    function rangeInfoLength(uint256 rid) external view returns (uint256) {
        return rangeInfo[rid].length;
    }

    function setMaxOpenNum(uint rid, uint256 newOpenNum) external onlyOwner {
        require(rid < roomInfo.length, "illegal rid");
        emit NewMaxOpenNum(roomInfo[rid].maxOpenNum, newOpenNum);
        roomInfo[rid].maxOpenNum = newOpenNum;
    }

    function setReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "receiver is zero");
        emit NewReceiver(receiver, _receiver);
        receiver = _receiver;
    }

    function setRewardReceiver(address _rewardReceiver) external onlyOwner {
        require(_rewardReceiver != address(0), "rewardReceiver is zero");
        emit NewRewardReceiver(rewardReceiver, _rewardReceiver);
        rewardReceiver = _rewardReceiver;
    }

    function beginLoop(uint _rid, uint _startAt) public {
        if (_rid >= roomInfo.length) {
            return;
        }
        RoomInfo storage room = roomInfo[_rid];
        if (block.timestamp <= room.loopFinishAt || block.timestamp > _startAt) {
            return;
        }
        room.currentLoop = room.currentLoop + 1;
        room.loopBeginAt = _startAt;
        room.loopFinishAt = _startAt.add(room.loopInterval);
        room.loopFinish = false;
        uint[] memory nftValues = new uint[](nftTypes[_rid].length);
        nftIDs[_rid][room.currentLoop] = nftToken.createBatchDefault(nftTypes[_rid], nftValues);
    }

    function finishLoop(uint _rid, uint _loop) public {
        if (_rid >= roomInfo.length) {
            return;
        }
        RoomInfo storage room = roomInfo[_rid];
        if (_loop != room.currentLoop || room.loopFinish || block.timestamp < room.loopFinishAt) {
            return;
        }
        room.loopFinish = true;
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, tx.origin, block.coinbase, block.number)));
        bytes32 requestId = _requestRandom(seed);
        require(randomInfo[requestId].to == address(0), "random already exists");
        randomInfo[requestId] = RandomInfo({
            to: address(this),
            rid: _rid,
            num: 1,
            loop: _loop
        });
        emit BuyBlindBox(_rid, address(this), _loop, 1, 0, 0, requestId);
    }

    constructor(IInvite _invite, IP2EERC1155 _nftToken, address _receiver, address _rewardReceiver, address _linkAccessor) Random(_linkAccessor) SafeOwnable(msg.sender) {
        require(address(_invite) != address(0), "invite address is zero");
        invite = _invite;
        require(address(_nftToken) != address(0), "nftToken is zero");
        nftToken = _nftToken;
        require(_receiver != address(0), "receiver is zero");
        receiver = _receiver;
        emit NewReceiver(address(0), receiver);
        require(_rewardReceiver != address(0), "rewardReceiver is zero");
        rewardReceiver = _rewardReceiver;
        emit NewRewardReceiver(address(0), rewardReceiver);
    }

    function add(
        IERC20 _token, uint256 _value, uint256 _valueFee, uint256 _loopInterval, uint256 _odds, uint256[] memory _nftTypes, uint256[] memory _nftPercents
    ) external onlyOwner {
        require(address(_token) != address(0), "rewardToken is zero address");
        roomInfo.push(RoomInfo({
            token: _token,
            value: _value,
            currentLoop: 0,
            loopBeginAt: 0,
            loopFinishAt: 0,
            loopFinish: false,
            loopInterval: _loopInterval,
            valueFee: _valueFee,
            rewardAmount: 0,
            odds: _odds,
            maxOpenNum: 1
        }));
        uint rid = roomInfo.length - 1;
        emit NewGameRoom(rid, _token, _value, _valueFee, _odds);
        require(_nftTypes.length == _nftPercents.length && _nftTypes.length > 0, "illegal type percent info");
        uint lastEndIndex = 0;
        for (uint i = 0; i < rangeInfo[rid].length; i ++) {
            lastEndIndex = rangeInfo[rid][i].endIndex;
        }
        for (uint i = 0; i < _nftTypes.length; i ++) {
            rangeInfo[rid].push(RangeInfo({
                nftType : _nftTypes[i],
                startIndex: lastEndIndex,
                endIndex: lastEndIndex.add(_nftPercents[i])
            }));
            nftTypes[rid].push(_nftTypes[i]);
            emit RoomRange(rid, _nftTypes[i], lastEndIndex, lastEndIndex.add(_nftPercents[i]));
            lastEndIndex = lastEndIndex.add(_nftPercents[i]);
        }
        require(lastEndIndex == MAX_END_INDEX, "illegal percent info");
        beginLoop(rid, block.timestamp);
    }

    function buyBlindBox(uint256 _rid, uint256 _num, address _to) external {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_num <= roomInfo[_rid].maxOpenNum, "illegal open num");
        require(block.timestamp >= room.loopBeginAt && block.timestamp <= room.loopFinishAt, "room not begin or already finish");
        uint payAmount = room.value.mul(_num);
        uint payFee = payAmount.mul(room.valueFee).div(VALUE_FEE_BASE);

        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, tx.origin, block.coinbase, block.number)));
        bytes32 requestId = _requestRandom(seed);
        require(randomInfo[requestId].to == address(0), "random already exists");
        randomInfo[requestId] = RandomInfo({
            to: _to,
            rid: _rid,
            num: _num,
            loop: room.currentLoop
        });
        blindBoxNum[_rid][_to] = blindBoxNum[_rid][_to].add(_num);

        address[] memory inviters = invite.inviterTree(_to, MAX_INVITE_HEIGHT);
        uint[] memory amounts = new uint[](inviters.length);
        uint totalInviterAmount = 0;
        for (uint i = 0; i < inviters.length; i ++) {
            uint percent = getInvitePercent(i);
            amounts[i] = payAmount.mul(percent).div(PERCENT_BASE); 
            totalInviterAmount = totalInviterAmount.add(amounts[i]);
        }
        SafeERC20.safeTransferFrom(room.token, msg.sender, address(invite), totalInviterAmount);
        //uint remainAmount = invite.sendReward(_to, room.token, amounts);
        invite.sendReward(_to, room.token, amounts);
        SafeERC20.safeTransferFrom(room.token, msg.sender, address(this), payAmount.sub(totalInviterAmount));
        if (payFee > 0) {
            SafeERC20.safeTransferFrom(room.token, msg.sender, receiver, payFee);
        }
        emit BuyBlindBox(_rid, _to, room.currentLoop, _num, payAmount, payFee, requestId);
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
                    uint nftId = nftIDs[random.rid][random.loop][rangeIndex];
                    nftToken.mint(random.to, nftId, 1, "0x");
                    emit OpenBlindBox(random.rid, random.loop, random.to, rangeIndex, _requestId);
                    if (random.to == address(this)) {
                        loopResult[random.rid][random.loop] = nftId;
                    }
                    break;
                }
            }
            require(rangeIndex < rangeInfo[random.rid].length, "rangeInfo error");
        }
        blindBoxNum[random.rid][random.to] = blindBoxNum[random.rid][random.to].sub(random.num);
        delete randomInfo[_requestId];

        super.finishRandom(_requestId);
    }

    function claim(uint256 _rid, uint256 _loop, address _to) external {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_loop < room.currentLoop || (_loop == room.currentLoop && room.loopFinish), "loop not finish");
        uint resultNftId = loopResult[_rid][_loop];
        uint balance = nftToken.balanceOf(_to, resultNftId);
        uint reward = room.value.mul(balance).mul(room.odds);
        require(reward > 0, "user not win");
        require(room.rewardAmount >= reward, "reward token not enough");
        room.rewardAmount = room.rewardAmount.sub(reward);
        nftToken.burn(_to, resultNftId, balance);
        SafeERC20.safeTransfer(room.token, _to, reward);
        emit Claim(_rid, _loop, _to, balance, reward);
    }

    function roomDeposit(uint _rid, uint _amount) external {
        require(_rid < roomInfo.length, "rid not exist");  
        RoomInfo storage room = roomInfo[_rid];
        uint balanceBefore = room.token.balanceOf(address(this));
        SafeERC20.safeTransferFrom(room.token, msg.sender, address(this), _amount);
        uint balanceAfter = room.token.balanceOf(address(this));
        require(balanceAfter > balanceBefore, "token transfer error");
        room.rewardAmount = room.rewardAmount.add(balanceAfter.sub(balanceBefore));
        emit RewardPoolDeposit(_rid, msg.sender, room.token, balanceAfter.sub(balanceBefore));
    }

    function roomWithdraw(uint _rid, uint _amount) external {
        require(msg.sender == owner(), "Caller not owner");
        require(_rid < roomInfo.length, "illegal rid");
        RoomInfo storage room = roomInfo[_rid];
        require(block.timestamp > room.loopFinishAt + 60 * 60 * 24 * 7, "the reward can be withdrawed only after 1 week");
        if (room.rewardAmount < _amount) {
            _amount = room.rewardAmount;
        }
        room.rewardAmount = room.rewardAmount.sub(_amount);
        SafeERC20.safeTransfer(room.token, rewardReceiver, _amount);
        emit RewardPoolWithdraw(_rid, rewardReceiver, room.token, _amount);
    }

    function userRecord(uint _rid, uint[] memory loops, address user) external view returns (uint[] memory){
        RoomInfo storage room = roomInfo[_rid];
        uint[] memory res = new uint[](loops.length);
        for (uint i = 0; i < loops.length; i ++) {
            if (loops[i] > room.currentLoop) {
                res[i] = 0;
            }
            uint resultNftId = loopResult[_rid][loops[i]];
            uint balance = nftToken.balanceOf(user, resultNftId);
            res[i] = balance.mul(room.odds);
        }
        return res;
    }
}
