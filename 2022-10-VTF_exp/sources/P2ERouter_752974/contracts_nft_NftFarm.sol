// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import '@openzeppelin/contracts/token/ERC1155/ERC1155.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '../interfaces/INftOracle.sol';
import '../token/TokenLocker.sol';
import '../core/SafeOwnable.sol';
import "../token/P2EToken.sol";

contract NftFarm is SafeOwnable, ReentrancyGuard, ERC1155, ERC1155Holder {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    enum NftType {ERC721, ERC1155}

    struct UserInfo {
        uint256 amount;     
        uint256 rewardDebt; 
    }

    struct PoolInfo {
        address nftContract;
        NftType nftType;
        address priceOracle;
        uint256 allocPoint;       
        uint256 lastRewardBlock;  
        uint256 accPerShare; 
        uint256 totalAmount;
    }

    P2EToken public rewardToken;
    uint256 public rewardPerBlock;
    uint256 public BONUS_MULTIPLIER;
    
    PoolInfo[] public poolInfo;
    mapping(address => uint256) public pidOfContract;
    mapping(address => bool) public existsContract;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;
    uint256 public startBlock;
    TokenLocker public tokenLocker;
    mapping(address => mapping(uint => uint)) nftIds;
    uint currentNftId;

    function getNftId(address _nftContract, uint _nftId) internal returns (uint) {
        uint currentId = nftIds[_nftContract][_nftId];
        if (currentId == 0) {
            currentId = currentNftId + 1;
            currentNftId = currentNftId + 1;
            nftIds[_nftContract][_nftId] = currentId;
        }
        return currentId;
    }
    
    event Deposit(address indexed user, uint256 indexed pid, uint256[] ids, uint256[] amounts);
    event Withdraw(address indexed user, uint256 indexed pid, uint256[] ids, uint256[] amounts);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256[] _ids, uint256 amount);
    event NewRewardPerBlock(uint oldReward, uint newReward);
    event NewMultiplier(uint oldMultiplier, uint newMultiplier);
    event NewPool(uint pid, NftType nftType, address nftContract, address priceOracle, uint allocPoint, uint totalPoint);
    event NewTokenLocker(TokenLocker oldTokenLocker, TokenLocker newTokenLocker);

    modifier validatePoolByPid(uint256 _pid) {
        require (_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    function setTokenLocker(TokenLocker _tokenLocker) external onlyOwner {
        //require(_tokenLocker != address(0), "token locker address is zero"); 
        emit NewTokenLocker(tokenLocker, _tokenLocker);
        tokenLocker = _tokenLocker;
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        internal
        view
        override
    {
        require(from == address(0) || to == address(0), "NFT CAN ONLY MINT OR BURN");
        require(operator == address(this), "NFT OPERATOR CAN ONLY BE THIS");
    }

    constructor(
        P2EToken _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) SafeOwnable(msg.sender) ERC1155("") {
        require(address(_rewardToken) != address(0), "illegal rewardToken");
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        BONUS_MULTIPLIER = 1;
    }

    function updateMultiplier(uint256 multiplierNumber, bool withUpdate) external onlyOwner {
        if (withUpdate) {
            massUpdatePools();
        }
        emit NewMultiplier(BONUS_MULTIPLIER, multiplierNumber);
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    function updateRewardPerBlock(uint256 _rewardPerBlock, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        emit NewRewardPerBlock(rewardPerBlock, _rewardPerBlock);
        rewardPerBlock = _rewardPerBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, NftType _nftType, address _nftContract, address _priceOracle, bool _withUpdate) external onlyOwner {
        require(_nftContract != address(0), "nftContract address is zero");
        require(address(_nftContract) != address(rewardToken), "can not add reward");
        require(!existsContract[_nftContract], "nftContract already exist");
        //check it is a legal nftContract
        if (_priceOracle == address(0)) {
            INftOracle(_nftContract).values(0); 
        } else {
            INftOracle(_priceOracle).valuesOf(_nftContract, 0);
        }
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pidOfContract[_nftContract] = poolInfo.length;
        existsContract[_nftContract] = true;
        poolInfo.push(PoolInfo({
            nftContract: _nftContract,
            nftType: _nftType,
            priceOracle: _priceOracle,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accPerShare: 0,
            totalAmount: 0
        }));

        emit NewPool(poolInfo.length - 1, _nftType, _nftContract, _priceOracle, _allocPoint, totalAllocPoint);
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner validatePoolByPid(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
        emit NewPool(_pid, poolInfo[_pid].nftType, poolInfo[_pid].nftContract, poolInfo[_pid].priceOracle, _allocPoint, totalAllocPoint);
    }

    function pendingReward(uint256 _pid, address _user) external validatePoolByPid(_pid) view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPerShare = pool.accPerShare;
        uint256 lpSupply = pool.totalAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 rewardReward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPerShare = accPerShare.add(rewardReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accPerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    
    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.totalAmount;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 rewardReward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        rewardReward = rewardToken.mint(address(this), rewardReward);
        pool.accPerShare = pool.accPerShare.add(rewardReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function getNftValue(PoolInfo storage pool, uint id) internal view returns (uint) {
        if (pool.priceOracle == address(0)) {
            return INftOracle(pool.nftContract).values(id); 
        } else {
            return INftOracle(pool.priceOracle).valuesOf(pool.nftContract, id);
        }
    }
    
    function deposit(uint256 _pid, uint[] memory _ids, uint[] memory _amounts) external nonReentrant validatePoolByPid(_pid) {
        require(_ids.length == _amounts.length, "illegal id num");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                if (address(tokenLocker) == address(0)) {
                    safeRewardTransfer(msg.sender, pending);
                } else {
                    rewardToken.approve(address(tokenLocker), pending);
                    tokenLocker.addReceiver(msg.sender, pending);
                }
            }
        }
        if (_ids.length > 0) {
            uint totalValues = 0;
            uint[] memory innerNftIds = new uint[](_ids.length);
            for (uint i = 0; i < _ids.length; i ++) {
                uint value = getNftValue(pool, _ids[i]);
                totalValues = totalValues.add(value);
                if (pool.nftType == NftType.ERC721) {
                    require(_amounts[i] == 1, "NFT721 CAN ONLY TRANSFER ONE BY ONE");
                    IERC721(pool.nftContract).safeTransferFrom(msg.sender, address(this), _ids[i]);
                }
                innerNftIds[i] = getNftId(pool.nftContract, _ids[i]);
            }
            if (pool.nftType == NftType.ERC1155) {
                IERC1155(pool.nftContract).safeBatchTransferFrom(msg.sender, address(this), _ids, _amounts, new bytes(0));
            }
            _mintBatch(msg.sender, innerNftIds, _amounts, new bytes(0));

            if (totalValues > 0) {
                user.amount = user.amount.add(totalValues);
                pool.totalAmount = pool.totalAmount.add(totalValues);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _ids, _amounts);
    }

    function withdraw(uint256 _pid, uint[] memory _ids, uint[] memory _amounts) external nonReentrant validatePoolByPid(_pid) {
        require(_ids.length == _amounts.length, "illegal id num");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            if (address(tokenLocker) == address(0)) {
                safeRewardTransfer(msg.sender, pending);
            } else {
                rewardToken.approve(address(tokenLocker), pending);
                tokenLocker.addReceiver(msg.sender, pending);
            }
        }
        if (_ids.length > 0) {
            uint totalValues = 0;
            uint[] memory innerNftIds = new uint[](_ids.length);
            for (uint i = 0; i < _ids.length; i ++) {
                uint value = getNftValue(pool, _ids[i]);
                totalValues = totalValues.add(value);
                if (pool.nftType == NftType.ERC721) {
                    require(_amounts[i] == 1, "NFT721 CAN ONLY TRANSFER ONE BY ONE");
                    IERC721(pool.nftContract).safeTransferFrom(address(this), msg.sender, _ids[i]);
                }
                innerNftIds[i] = nftIds[pool.nftContract][_ids[i]];
                require(innerNftIds[i] != 0, "nftContract Id Not exists");
            }
            if (pool.nftType == NftType.ERC1155) {
                IERC1155(pool.nftContract).safeBatchTransferFrom(address(this), msg.sender, _ids, _amounts, new bytes(0));
            }
            _burnBatch(msg.sender, innerNftIds, _amounts);

            require(user.amount >= totalValues, "withdraw: not good");
            if(totalValues > 0) {
                user.amount = user.amount.sub(totalValues);
                pool.totalAmount = pool.totalAmount.sub(totalValues);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _ids, _amounts);
    }

    function emergencyWithdraw(uint256 _pid, uint[] memory _ids) external nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (_ids.length > 0) {
            address[] memory accounts = new address[](_ids.length);
            uint[] memory innerNftIds = new uint[](_ids.length);
            uint[] memory amounts = new uint[](_ids.length);
            for (uint i = 0; i < _ids.length; i ++) {
                if (pool.nftType == NftType.ERC721) {
                    IERC721(pool.nftContract).safeTransferFrom(address(this), msg.sender, _ids[i]);
                    amounts[i] = 1;
                }
                innerNftIds[i] = nftIds[pool.nftContract][_ids[i]];
                require(innerNftIds[i] != 0, "nftContract Id Not exists");
                accounts[i] = msg.sender;
            }
            if (pool.nftType == NftType.ERC1155) {
                amounts = IERC1155(pool.nftContract).balanceOfBatch(accounts, innerNftIds);
                IERC1155(pool.nftContract).safeBatchTransferFrom(address(this), msg.sender, _ids, amounts, new bytes(0));
            }
            _burnBatch(msg.sender, innerNftIds, amounts);
        }

        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        emit EmergencyWithdraw(msg.sender, _pid, _ids, amount);
    }

    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint currentBalance = IERC20(rewardToken).balanceOf(address(this));
        if (currentBalance < _amount) {
            _amount = currentBalance;
        }
        IERC20(rewardToken).safeTransfer(_to, _amount);
    }

}
