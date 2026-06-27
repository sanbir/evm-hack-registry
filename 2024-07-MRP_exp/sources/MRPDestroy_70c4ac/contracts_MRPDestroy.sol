// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ITrigger} from "./interface/ITrigger.sol";
import {IPledge} from "./interface/IPledge.sol";
import {ILPDividends} from "./interface/ILPDividends.sol";
import {IInvite} from "./interface/IInvite.sol";
import {IMRPMiner} from "./interface/IMRPMiner.sol";


contract MRPDestroy is ERC20, AccessControl, ITrigger, IPledge {

    bool public online;

    uint8 public levelDepth = 20;

    uint256 public levelAmount = 1 ether / 10;

    uint256 public levelGas = 5e5;

    uint256 public dividendsPool;

    address public mrp;

    IInvite public invite;

    address public lpDividends;

    uint256 public minAmount = 100 ether;

    uint public dividendsFeeByBeforeOnline = 29;

    uint public lpFeeByBeforeOnline = 50;

    uint public dividendsFeeByAfterOnline = 29;

    uint public lpFeeByAfterOnline = 30;

    uint public destroyFeeByAfterOnline = 20;

    uint256 public LPAmount;

    uint256 public totalDestroy;

    uint256 public dividends;

    mapping(uint256 => bool) public dividendsPoolDayFlag;

    mapping(address => uint256) public destroyAccount;

    mapping(address => uint256) public accountDividends;

    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");

    event DestroyMRP(
        uint256 indexed amount
    );

    event DividendsUpdate(
        uint256 indexed dividends,
        uint256 indexed newestDividends
    );

    event AccountDestroyAmount(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed dividends
    );

    event AccountDividends(
        address indexed account,
        uint256 indexed oldDividends,
        uint256 indexed newestDividends
    );

    event ClaimDividends(
        address indexed account,
        uint256 indexed amount
    );

    event Reward(
        address indexed account,
        address indexed parent,
        uint256 indexed amount
    );

    event DailyDividendsPool(
        uint256 indexed dayNum,
        uint256 indexed amount
    );

    error INSUFFICIENT_AMOUNT();
    error INSUFFICIENT_TRANSFER();

    constructor(address _mrp, address _invite) ERC20("MRPDestroy", "MRPDestroy"){
        mrp = _mrp;
        invite = IInvite(_invite);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(TOKEN_ROLE, _msgSender());
        _grantRole(TOKEN_ROLE, mrp);
    }

    function _dividendsHandle(uint256 amount) internal {
        uint256 dividendsFee = online ? dividendsFeeByAfterOnline : dividendsFeeByBeforeOnline;
        uint256 dividendsAmount = amount * dividendsFee / 100;
        uint256 nowDividends = dividendsAmount * 20 / 100;
        uint256 delayDividends = dividendsAmount * 80 / 100;
        dividendsPool += delayDividends;
        if (totalDestroy == 0) {
            LPAmount += nowDividends;
        } else {
            _addDividends(nowDividends);
        }
    }

    function _dailyHandle() internal {
        uint256 dayNum = getDayNum();
        if (!dividendsPoolDayFlag[dayNum]) {
            dividendsPoolDayFlag[dayNum] = true;
            if(dividendsPool > 1 ether){
                dividendsPool = dividendsPool / 2;
                _addDividends(dividendsPool);
                emit DailyDividendsPool(dayNum, dividendsPool);
            }
        }
    }

    function setBefore(uint _dividendsFeeByBeforeOnline, uint _lpFeeByBeforeOnline) public onlyRole(DEFAULT_ADMIN_ROLE) {
        dividendsFeeByBeforeOnline = _dividendsFeeByBeforeOnline;
        lpFeeByBeforeOnline = _lpFeeByBeforeOnline;
    }

    function setAfter(uint _dividendsFeeByAfterOnline, uint _lpFeeByAfterOnline, uint _destroyFeeByAfterOnline) public onlyRole(DEFAULT_ADMIN_ROLE) {
        dividendsFeeByAfterOnline = _dividendsFeeByAfterOnline;
        lpFeeByAfterOnline = _lpFeeByAfterOnline;
        destroyFeeByAfterOnline = _destroyFeeByAfterOnline;
    }

    function _destroyHandle(address account, uint256 amount) internal {
        uint256 destroyAmount = 0;
        uint256 remainderAmount = _reward(account, amount);
        if (online) {
            destroyAmount = amount * destroyFeeByAfterOnline / 100;
            if (remainderAmount > 0) {
                destroyAmount += remainderAmount;
            }
        } else {
            LPAmount += remainderAmount;
        }
        if (destroyAmount > 0) {
            IERC20(mrp).transfer(address(0xdead), destroyAmount);
            emit DestroyMRP(destroyAmount);
        }
    }

    function _lpHandle(uint256 amount) internal {
        if (!online) {
            uint256 lpFee = amount * lpFeeByBeforeOnline / 100;
            LPAmount += lpFee;
        } else {
            uint256 lpFee = amount * lpFeeByAfterOnline / 100;
            IERC20(mrp).transfer(lpDividends, lpFee);
            ILPDividends(lpDividends).LPDividendsHandle(lpFee);
        }
    }

    function handle(address account, uint256 amount) public override onlyRole(TOKEN_ROLE) returns (bool){
        _dailyHandle();
        if (!hasRole(TOKEN_ROLE, account)) {
            if (amount < minAmount) revert INSUFFICIENT_AMOUNT();
            _destroyHandle(account, amount);
            _lpHandle(amount);
            _dividendsHandle(amount);
            _claimDividends(account);
            totalDestroy += amount;
            destroyAccount[account] += amount;
            emit AccountDestroyAmount(account, amount, dividends);
        } else {
            _addDividends(amount);
        }
        return true;
    }

    function setLevel(uint8 _levelDepth, uint256 _levelAmount, uint256 _levelGas) public onlyRole(DEFAULT_ADMIN_ROLE) {
        levelDepth = _levelDepth;
        levelAmount = _levelAmount;
        levelGas = _levelGas;
    }

    function setMRP(address _mrp) public onlyRole(DEFAULT_ADMIN_ROLE) {
        mrp = _mrp;
        _grantRole(TOKEN_ROLE, mrp);
    }

    function setInvite(address _invite) public onlyRole(DEFAULT_ADMIN_ROLE) {
        invite = IInvite(_invite);
    }

    function setMinAmount(uint256 _minAmount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        minAmount = _minAmount;
    }

    function dividendHandle(uint256 amount) public onlyRole(TOKEN_ROLE)
    {
        _dailyHandle();
        _addDividends(amount);
    }

    function _addDividends(uint256 amount) internal {
        if (amount <= 0) revert INSUFFICIENT_AMOUNT();
        if (totalDestroy == 0) {
            LPAmount += amount;
        } else {
            uint256 dividendsAmount = amount * 1 ether / totalDestroy;
            dividends += dividendsAmount;
            emit DividendsUpdate(dividendsAmount, dividends);
        }
    }

    function balanceOf(address account) public override view returns (uint256){
        uint256 amount = destroyAccount[account];
        if (amount <= 0) return 0;
        uint256 dividendsAccount = dividends - accountDividends[account];
        if (dividendsAccount <= 0) return 0;
        return amount * dividendsAccount / 1 ether;
    }

    function _claimDividends(address account) internal {
        uint256 mrpAmount = balanceOf(account);
        if (mrpAmount > 0) {
            IERC20(mrp).transfer(account, mrpAmount);
            emit ClaimDividends(account, mrpAmount);
        }
        emit AccountDividends(account, accountDividends[account], dividends);
        accountDividends[account] = dividends;
    }

    function withdrawLp(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!online && LPAmount > 0) {
            IERC20(mrp).transfer(account, LPAmount);
            online = true;
        }
    }

    function offOnline() public onlyRole(DEFAULT_ADMIN_ROLE) {
        online = false;
    }

    function setLPDividends(address _lpDividends) public onlyRole(DEFAULT_ADMIN_ROLE) {
        lpDividends = _lpDividends;
    }

    function transfer(address to, uint256 value) public override returns (bool){
        uint256 balance = balanceOf(_msgSender());
        if (balance <= 0 || _msgSender() != to) revert INSUFFICIENT_TRANSFER();
        _claimDividends(_msgSender());
        return true;
    }

    function _reward(address member, uint256 amount) internal returns (uint256) {
        address parent = invite.getParent(member);
        uint256 rewardAmount = amount / 100;
        uint256 firstRewardAmount = rewardAmount * 2;
        uint8 depth = 1;
        uint256 gasLeft = gasleft();
        uint256 gasUsed = 0;
        uint256 remainderAmount = amount * (levelDepth + 1) / 100;
        IMRPMiner miner = IMRPMiner(mrp);
        while (depth <= levelDepth && gasUsed < levelGas && parent != address(0) && remainderAmount > 0) {
            if (depth * levelAmount <= miner.getMinerBalanceOf(parent) && destroyAccount[parent] > 0) {
                uint256 MRPAmount = depth == 1 ? firstRewardAmount : rewardAmount;
                IERC20(mrp).transfer(parent, MRPAmount);
                remainderAmount -= MRPAmount;
                emit Reward(member, parent, MRPAmount);
                depth++;
            }
            parent = invite.getParent(parent);
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) {
                gasUsed += (gasLeft - newGasLeft);
            }
            gasLeft = newGasLeft;
        }
        return remainderAmount;
    }

    function getDayNum() public view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
