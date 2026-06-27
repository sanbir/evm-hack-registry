//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct User {
    uint256 amount;
    uint256 time;
    uint256 points;
    uint256 epoc;
    uint256 totalClaimed;
}

struct Epoc {
    uint256 time;
    uint256 ppt; // point per token
    uint256 epp; // earning per point
    uint256 epn; // earning per xloot nft
    uint256 value; // total revenue in the epoc
}

struct BonusLoot {
    uint256 amount; // total bonus amount
    uint256 epp; // earning per point
    uint256 epn; // earning per xloot
}

struct Loot {
    address token;
    uint256 totalAmount;
    uint256 totalPoints;
    uint256 lastUpdate;
    uint256 ippt; // initial loot point per token
}

struct XLoot {
    address token;
    uint256 xppt; // xloot point per token
    uint256 tpn; // token per nft conversion rate
    uint256 supply;
    mapping(uint256 => uint256) nextRedeem; // last claim epoc by id
}

struct Config {
    uint16 maxRedeemEpoc;
    uint16 stakingScale;
    uint16 gapCount;
    uint32 epocDuration;
    uint176 gap;
}

contract Staking is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable
{
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint16 public constant MAX_REDEEM_EPOC = 50;
    uint16 public constant STAKING_SCALE = 5;
    uint16 public constant GAP_COUNT = 150;
    uint32 public constant EPOC_DURATION = 7 days;
    uint256 public constant PPT_STARTING = 100 gwei;
    uint256 public constant PPTX_STARTING = 300 gwei;
    uint256 public constant LOOTWEI = 1 ether;

    struct StakingStorage {
        mapping(address => User) users; // staking
        mapping(uint256 => Epoc) epocs; // revenue share by epoc
        mapping(uint256 => BonusLoot) bonus; // bonus token by epoc
        uint256 nextEpocId; // next ditributed epoc
        uint256 totalRewarded; // total ETH rewarded
        Loot loot;
        XLoot xloot;
        Config config;
        uint256 totalUsers;
    }

    // keccak256(abi.encode(uint256(keccak256("loot.storage.Staking")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StakingStorageLocation =
        0x38f9467de66b890b87f32a7c97aed89eb60847b692ceb4f5b98fb6bd51995900;

    function _getOwnStorage() private pure returns (StakingStorage storage $) {
        assembly {
            $.slot := StakingStorageLocation
        }
    }

    event StakingLoot(address user, uint256 amount, uint256 time);
    event UnStakingLoot(address user, uint256 amount, uint256 time);
    event CommitEpoc(
        uint256 epoc,
        uint256 value,
        uint256 epp,
        uint256 epn,
        uint256 time
    );
    event Redeem(
        address user,
        uint256[] xloots,
        uint256 amount,
        uint256 epoc,
        uint256 time,
        uint256 duration
    );

    event UpdateConfig(string name, uint256 value);

    event AddBonusLoot(uint256 totalAmount, uint256 numEpoc, uint256 fromEpoc);
    event RemoveBonusLoot(
        uint256 totalAmount,
        uint256 numEpoc,
        uint256 fromEpoc
    );

    function initialize(
        address lootAddress,
        address xlootAddress,
        uint256 firstEpocTime
    ) public initializer {
        __Ownable_init(msg.sender);
        __AccessControl_init_unchained();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        // init value
        StakingStorage storage $ = _getOwnStorage();

        // init config
        $.config.maxRedeemEpoc = MAX_REDEEM_EPOC;
        $.config.stakingScale = STAKING_SCALE;
        $.config.gapCount = GAP_COUNT;
        $.config.epocDuration = EPOC_DURATION;

        // init loot
        $.loot.ippt = PPT_STARTING; // start point per token
        $.loot.token = lootAddress;

        // init xloot
        $.xloot.tpn = 15_000 * LOOTWEI; // current burn rate 15k loot => 1 xLoot
        $.xloot.xppt = PPTX_STARTING; // point per token of xloot nft
        $.xloot.token = xlootAddress;

        // init epoc
        Epoc memory newEpoc;
        newEpoc.ppt = (PPTX_STARTING - PPT_STARTING) / GAP_COUNT; // point increasing each day in epoc
        newEpoc.time = firstEpocTime;
        $.nextEpocId = 1;
        $.epocs[$.nextEpocId] = newEpoc;

        // init supply
        _updateXLoot();
    }

    receive() external payable {
        StakingStorage storage $ = _getOwnStorage();
        Epoc storage _nextEpoc = $.epocs[$.nextEpocId];
        _nextEpoc.value += msg.value;

        if (_nextEpoc.time <= block.timestamp) {
            _commitEpoc();
        }
    }

    function _commitEpoc() internal {
        StakingStorage storage $ = _getOwnStorage();

        // scan for new xloot
        _updateXLoot();

        Epoc storage _currentEpoc = $.epocs[$.nextEpocId];
        Epoc memory _newEpoc;
        _newEpoc.time = _currentEpoc.time + $.config.epocDuration; // estimate next epoc
        _currentEpoc.time = block.timestamp; // real epoc time
        if (_newEpoc.time <= _currentEpoc.time) {
            _newEpoc.time = _currentEpoc.time + $.config.epocDuration; // reupdate if the next epoc time is over
        }

        // calculate current epoc revshare
        $.loot.totalPoints +=
            ((((_currentEpoc.time - $.loot.lastUpdate) * _currentEpoc.ppt) /
                1 days) * $.loot.totalAmount) /
            LOOTWEI;
        $.loot.lastUpdate = _currentEpoc.time;
        // calculate xloot point per token
        uint256 lastEpocTime = $.nextEpocId > 1
            ? $.epocs[$.nextEpocId - 1].time
            : _currentEpoc.time;
        $.xloot.xppt +=
            ((_currentEpoc.time - lastEpocTime) * _currentEpoc.ppt) /
            1 days;

        uint256 ppn = ($.xloot.xppt * $.xloot.tpn) / LOOTWEI;
        uint256 totalPoints = $.loot.totalPoints + ppn * $.xloot.supply;

        if (totalPoints > 0) {
            // earning per point
            _currentEpoc.epp = (_currentEpoc.value * (1 gwei)) / totalPoints;
            _currentEpoc.epn = (_currentEpoc.epp * ppn) / 1 gwei;
            // add epoc
            emit CommitEpoc(
                $.nextEpocId,
                _currentEpoc.value,
                _currentEpoc.epp,
                _currentEpoc.epn,
                _currentEpoc.time
            );

            // update ippt & ppt
            uint256 _ippt = $.xloot.xppt / $.config.stakingScale;
            if ($.loot.ippt < _ippt) $.loot.ippt = _ippt;
            _newEpoc.ppt = ($.xloot.xppt - $.loot.ippt) / $.config.gapCount;

            // calculate distribution for bonus token
            BonusLoot storage bonusLoot = $.bonus[$.nextEpocId];
            if (bonusLoot.amount > 0) {
                bonusLoot.epp = (bonusLoot.amount * (1 gwei)) / totalPoints;
                bonusLoot.epn = (bonusLoot.epp * ppn) / 1 gwei;
            }

            // new next Epoc
            $.nextEpocId++;
            $.epocs[$.nextEpocId] = _newEpoc;

            // update total payout value
            $.totalRewarded += _currentEpoc.value;
        }
    }

    function redeem(uint256[] memory xloots) external {
        _redeemLoot(msg.sender, xloots);
    }

    ///////// STAKING ///////////
    function stake(uint256 amount) external {
        require(amount > 0, "Invalid Amount");
        StakingStorage storage $ = _getOwnStorage();

        // transfer loot to this contract
        _transferIn($.loot.token, msg.sender, amount);

        // redeem before update staking
        _redeemLoot(msg.sender, new uint256[](0));

        // update staking
        _stake(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        StakingStorage storage $ = _getOwnStorage();
        // redeem before update unstaking
        _redeemLoot(msg.sender, new uint256[](0));

        // now update staking data
        Epoc storage _nextEpoc = $.epocs[$.nextEpocId];
        User storage _user = $.users[msg.sender];
        require(amount > 0 && amount <= _user.amount, "Invalid Amount");
        // transfer loot to user
        _transferOut($.loot.token, msg.sender, amount);

        // total user points upto now
        uint256 points = _user.points +
            ((((block.timestamp - _user.time) * _nextEpoc.ppt) / 1 days) *
                _user.amount) /
            LOOTWEI;
        // remove points to unstake amount
        uint256 removePoints = (points * amount) / _user.amount;

        _user.points = points - removePoints;
        _user.amount -= amount;
        _user.time = block.timestamp;

        // update user
        if (_user.amount == 0) {
            $.totalUsers--;
        }

        // update total
        $.loot.totalPoints =
            $.loot.totalPoints +
            ($.loot.totalAmount *
                (((block.timestamp - $.loot.lastUpdate) * _nextEpoc.ppt) /
                    1 days)) /
            LOOTWEI -
            removePoints;
        $.loot.totalAmount -= amount;
        $.loot.lastUpdate = block.timestamp;

        emit UnStakingLoot(msg.sender, amount, block.timestamp);
    }

    /////// INTERNAL //////////
    function _redeemLoot(address account, uint256[] memory xloots) internal {
        StakingStorage storage $ = _getOwnStorage();
        User storage _user = $.users[account];

        (
            uint256 claimable,
            uint256 bonusAmount,
            uint256 time,
            uint256 duration,
            uint256 points
        ) = _redeemable(account, xloots);

        // update user status
        if (_user.amount > 0 && _user.epoc < $.nextEpocId - 1) {
            if (points > 0) _user.points = points;
            if (time > 0) _user.time = time;
        }

        // update last epoc redeemed for user & xloot
        _user.epoc = $.nextEpocId - 1;
        if (xloots.length > 0) {
            for (uint256 i = 0; i < xloots.length; i++) {
                $.xloot.nextRedeem[xloots[i]] = $.nextEpocId;
            }
        }

        if (claimable > 0) {
            _user.totalClaimed += claimable;
            (bool success, ) = account.call{value: claimable}("");
            require(success, "Transfer Fail");
            emit Redeem(
                account,
                xloots,
                claimable,
                $.nextEpocId - 1,
                block.timestamp,
                duration
            );
        }

        // auto staking bonus $loot for user
        if (bonusAmount > 0) {
            _stake(account, bonusAmount);
        }
    }

    function _redeemable(
        address account,
        uint256[] memory xloots
    )
        internal
        view
        returns (
            uint256 claimable,
            uint256 bonusAmount,
            uint256 time,
            uint256 duration,
            uint256 points
        )
    {
        StakingStorage storage $ = _getOwnStorage();
        User memory _user = $.users[account];
        uint256 _fromTime = 0;

        uint256 _currEpocId = $.nextEpocId - 1;
        // bonus token
        if (_user.amount > 0 && _user.epoc < _currEpocId) {
            points = _user.points;
            time = _user.time;
            uint256 fromEpoc = _user.epoc + 1;
            if (fromEpoc + $.config.maxRedeemEpoc < $.nextEpocId) {
                fromEpoc = $.nextEpocId - $.config.maxRedeemEpoc;
            }
            if (fromEpoc > 0) {
                _fromTime = $.epocs[fromEpoc].time;
            }
            for (uint256 i = fromEpoc; i < $.nextEpocId; i++) {
                Epoc memory _epoc = $.epocs[i];
                points +=
                    ((((_epoc.time - time) * _epoc.ppt) / 1 days) *
                        _user.amount) /
                    LOOTWEI;
                claimable += (points * _epoc.epp) / (1 gwei);
                time = _epoc.time;
                // calculate bonus token
                BonusLoot memory bonusLoot = $.bonus[i];
                if (bonusLoot.amount > 0) {
                    bonusAmount += (bonusLoot.epp * points) / 1 gwei;
                }
            }
        }

        uint256 nextEpocTime = $.epocs[$.nextEpocId].time;
        // already redeem epoc
        _user.epoc = $.nextEpocId - 1;

        if (xloots.length > 0) {
            for (uint256 i = 0; i < xloots.length; i++) {
                uint256 id = xloots[i];
                IERC721 _xloot = IERC721($.xloot.token);
                require(_xloot.ownerOf(id) == account, "Invalid xLoot Owner");
                if (
                    $.xloot.nextRedeem[id] > 0 &&
                    $.xloot.nextRedeem[id] < $.nextEpocId
                ) {
                    uint256 fromEpoc = $.xloot.nextRedeem[id];
                    // check max number of epoc redeem allow
                    if (fromEpoc + $.config.maxRedeemEpoc < $.nextEpocId) {
                        fromEpoc = $.nextEpocId - $.config.maxRedeemEpoc;
                    }
                    if (fromEpoc > 0) {
                        if (
                            _fromTime == 0 ||
                            _fromTime >= $.epocs[fromEpoc].time
                        ) {
                            _fromTime = $.epocs[fromEpoc].time;
                        }
                    }
                    // redeem all epoc
                    for (uint256 j = fromEpoc; j < $.nextEpocId; j++) {
                        claimable += $.epocs[j].epn;
                        // calculate bonus token
                        BonusLoot memory bonusLoot = $.bonus[j];
                        if (bonusLoot.amount > 0) {
                            bonusAmount += bonusLoot.epn;
                        }
                    }
                }
            }
        }

        if (claimable > 0) {
            duration = nextEpocTime - _fromTime;
        }
    }

    function _transferOut(address token, address to, uint256 amount) internal {
        IERC20 _token = IERC20(token);
        _token.transfer(to, amount);
    }

    function _transferIn(address token, address from, uint256 amount) internal {
        IERC20 _token = IERC20(token);
        _token.transferFrom(from, address(this), amount);
    }

    function _updateXLoot() internal {
        StakingStorage storage $ = _getOwnStorage();
        // scan for new xloot
        uint256 i = $.xloot.supply;
        bool done = false;
        IERC721 _xloot = IERC721($.xloot.token);
        while (!done) {
            try _xloot.ownerOf(i) returns (address _xloodOwner) {
                if (_xloodOwner != address(0)) {
                    $.xloot.nextRedeem[i++] = $.nextEpocId;
                } else done = true;
            } catch {
                done = true;
            }
        }
        $.xloot.supply = i;
    }

    function _stake(address account, uint256 amount) internal {
        StakingStorage storage $ = _getOwnStorage();

        // now update staking data
        Epoc storage _nextEpoc = $.epocs[$.nextEpocId];
        User storage _user = $.users[account];

        if (_user.amount > 0) {
            // add points for current staking upto now
            _user.points +=
                ((((block.timestamp - _user.time) * _nextEpoc.ppt) / 1 days) *
                    _user.amount) /
                LOOTWEI;
        } else {
            $.totalUsers++;
        }
        // initial points for new staking
        uint256 newPoints = (amount * $.loot.ippt) / LOOTWEI;
        _user.points += newPoints;
        _user.amount += amount;
        _user.time = block.timestamp;

        // update total
        $.loot.totalPoints +=
            ($.loot.totalAmount *
                (((block.timestamp - $.loot.lastUpdate) * _nextEpoc.ppt) /
                    1 days)) /
            LOOTWEI +
            newPoints;
        $.loot.totalAmount += amount;
        $.loot.lastUpdate = block.timestamp;

        emit StakingLoot(account, amount, block.timestamp);
    }

    ///// GETTER /////
    function nextEpocId() external view returns (uint256) {
        StakingStorage storage $ = _getOwnStorage();
        return $.nextEpocId;
    }

    function nextEpoc() external view returns (Epoc memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.epocs[$.nextEpocId];
    }

    function currentEpoc() external view returns (Epoc memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.epocs[$.nextEpocId - 1];
    }

    function epoc(uint256 id) external view returns (Epoc memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.epocs[id];
    }

    function user(address account) external view returns (User memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.users[account];
    }

    function loot() external view returns (Loot memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.loot;
    }

    function xloot()
        external
        view
        returns (address token, uint256 ppt, uint256 tpn, uint256 supply)
    {
        StakingStorage storage $ = _getOwnStorage();
        token = $.xloot.token;
        ppt = $.xloot.xppt;
        tpn = $.xloot.tpn;
        supply = $.xloot.supply;
    }

    function totalRewarded() external view returns (uint256) {
        StakingStorage storage $ = _getOwnStorage();
        return $.totalRewarded;
    }

    // GET TOTAL USER STAKING
    function totalUser() external view returns (uint256) {
        StakingStorage storage $ = _getOwnStorage();
        return $.totalUsers;
    }

    function config() external view returns (Config memory) {
        StakingStorage storage $ = _getOwnStorage();
        return $.config;
    }

    // get claimable revenue share in ETH and $LOOT bonus token up to date
    function claimableOf(
        address account,
        uint256[] memory xloots
    )
        external
        view
        returns (uint256 claimable, uint256 bonusAmount, uint256 duration)
    {
        (claimable, bonusAmount, , duration, ) = _redeemable(account, xloots);
    }

    function xLootNextReem(uint256 xlootId) external view returns (uint256) {
        StakingStorage storage $ = _getOwnStorage();
        return $.xloot.nextRedeem[xlootId];
    }

    // average staking point of a user compare to xloot point per token, gwei base
    function stakingPointOf(
        address account
    ) external view returns (uint256 stakingPoint) {
        StakingStorage storage $ = _getOwnStorage();
        User memory _user = $.users[account];
        if (_user.amount > 0 && $.xloot.xppt > 0) {
            uint256 _points = _user.points;
            uint256 _time = _user.time;
            uint256 fromEpoc = _user.epoc + 1;
            if (fromEpoc + $.config.maxRedeemEpoc < $.nextEpocId) {
                fromEpoc = $.nextEpocId - $.config.maxRedeemEpoc;
            }
            for (uint256 i = fromEpoc; i < $.nextEpocId; i++) {
                Epoc memory _epoc = $.epocs[i];
                _points +=
                    ((((_epoc.time - _time) * _epoc.ppt) / 1 days) *
                        _user.amount) /
                    LOOTWEI;
                _time = _epoc.time;
            }

            stakingPoint =
                (((_points * LOOTWEI) / _user.amount) * 1 gwei) /
                $.xloot.xppt;
        }
    }

    ///// SETTER /////
    function setMaxRedeemEpoc(
        uint16 maxRedeemEpoc
    ) external onlyRole(OPERATOR_ROLE) {
        require(maxRedeemEpoc > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();
        $.config.maxRedeemEpoc = maxRedeemEpoc;
        emit UpdateConfig("MaxRedeemEpoc", maxRedeemEpoc);
    }

    function setStakingScale(
        uint16 stakingScale
    ) external onlyRole(OPERATOR_ROLE) {
        require(stakingScale > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();
        $.config.stakingScale = stakingScale;
        emit UpdateConfig("StakingScale", stakingScale);
    }

    function setGapCount(uint16 gapCount) external onlyRole(OPERATOR_ROLE) {
        require(gapCount > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();
        $.config.gapCount = gapCount;
        emit UpdateConfig("GapCount", gapCount);
    }

    function setEpocDuration(
        uint32 epocDuration
    ) external onlyRole(OPERATOR_ROLE) {
        require(epocDuration > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();
        $.config.epocDuration = epocDuration;
        emit UpdateConfig("EpocDuration", epocDuration);
    }

    ///// SYSTEM /////
    // Add bonus token for next numEpoc.
    // Bonus token will automatic distribute on current epoc
    function addBonusLoot(
        uint256 totalAmount,
        uint256 numEpoc
    ) external onlyRole(OPERATOR_ROLE) {
        require(totalAmount > 0 && numEpoc > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();

        // transfer token to this contract
        _transferIn($.loot.token, msg.sender, totalAmount);

        // update distribution allocation
        uint256 amount = totalAmount / numEpoc;
        for (uint256 eId = $.nextEpocId; eId < $.nextEpocId + numEpoc; eId++) {
            BonusLoot storage bonusLoot = $.bonus[eId];
            bonusLoot.amount += amount;
        }

        emit AddBonusLoot(totalAmount, numEpoc, $.nextEpocId);
    }

    // Remove bonus token for next numEpoc.
    // Revert for previous added
    function removeBonusLoot(
        uint256 totalAmount,
        uint256 numEpoc
    ) external onlyRole(OPERATOR_ROLE) {
        require(totalAmount > 0 && numEpoc > 0, "Invalide Input");
        StakingStorage storage $ = _getOwnStorage();

        // update distribution allocation
        uint256 amount = totalAmount / numEpoc;
        // Make sure token already planned and enough allocations to remove
        for (uint256 eId = $.nextEpocId; eId < $.nextEpocId + numEpoc; eId++) {
            BonusLoot storage bonusLoot = $.bonus[eId];
            require(
                bonusLoot.amount >= amount,
                "Not Enough Allocations To Remove"
            );
        }

        for (uint256 eId = $.nextEpocId; eId < $.nextEpocId + numEpoc; eId++) {
            BonusLoot storage bonusLoot = $.bonus[eId];
            bonusLoot.amount -= amount;
        }

        // transfer out token to operator
        _transferOut($.loot.token, msg.sender, totalAmount);

        emit RemoveBonusLoot(totalAmount, numEpoc, $.nextEpocId);
    }
}
