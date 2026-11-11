// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Suzaku Core — Rewards::_calculateAndStoreVaultShares (Cyfrin, 2025-07-07)
    Vault rewards are scaled by operatorBeneficiariesShares, the operator's
    cross-asset-class total, instead of that vault's asset-class share.

    Operator B stakes 700/1000 in class 1 (50% of rewards), 100/100 in class 2
    (20%), and 100/100 in class 3 (30%). Cross-asset total = 8500 bp.
    Vault 2 is 100% of the operator's class-2 stake, so it should be paid the
    class-2 share of 2000 bp = 20,000 of a 100,000 reward epoch.
    The buggy third mulDiv scales 2000 by 8500/10000 and pays 17,000.
    The 3,000 gap is reclaimed as undistributed. The control multiplies by the
    asset-class share only and pays 20,000.
*/

library Math {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return (a * b) / denominator;
    }
}

contract Dai {
    string public name = "Suzaku Reward";
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Middleware {
    uint96[] internal ids;
    mapping(uint48 => mapping(address => mapping(uint96 => uint256))) public operatorStake;
    mapping(uint48 => mapping(uint96 => uint256)) public totals;

    function setAssetClasses(uint96 a, uint96 b, uint96 c) external {
        ids = new uint96[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    function getAssetClassIds() external view returns (uint96[] memory) {
        return ids;
    }

    function setOperatorStake(uint48 epoch, address operator, uint96 assetClass, uint256 amount) external {
        operatorStake[epoch][operator][assetClass] = amount;
    }

    function setTotalStake(uint48 epoch, uint96 assetClass, uint256 amount) external {
        totals[epoch][assetClass] = amount;
    }

    function getOperatorUsedStakeCachedPerEpoch(uint48 epoch, address operator, uint96 assetClass)
        external
        view
        returns (uint256)
    {
        return operatorStake[epoch][operator][assetClass];
    }

    function totalStakeCache(uint48 epoch, uint96 assetClass) external view returns (uint256) {
        return totals[epoch][assetClass];
    }
}

contract VaultManager {
    mapping(address => uint96) public assetClassOf;

    function setVaultAssetClass(address vault, uint96 assetClass) external {
        assetClassOf[vault] = assetClass;
    }

    function getVaultAssetClass(address vault) external view returns (uint96) {
        return assetClassOf[vault];
    }
}

contract RewardsBase {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 public constant EPOCH_REWARDS = 100_000e18;
    address internal constant OPERATOR_B = 0x000000000000000000000000000000000000b0b0;
    address internal constant VAULT2 = 0x0000000000000000000000000000000000000002;
    address internal constant VAULT3 = 0x0000000000000000000000000000000000000003;
    address internal constant STAKER = 0x000000000000000000000000000000000000bEEF;
    address internal constant RECLAIMER = 0x000000000000000000000000000000000000fEee;

    Dai public immutable token;
    Middleware public immutable l1Middleware;
    VaultManager public immutable middlewareVaultManager;

    mapping(uint96 => uint16) public rewardsSharePerAssetClass;
    mapping(uint48 => mapping(address => uint256)) public operatorBeneficiariesShares;
    mapping(uint48 => mapping(address => mapping(uint96 => uint256))) public operatorClassShares;
    mapping(uint48 => mapping(address => uint256)) public vaultShares;
    mapping(address => uint256) public vaultStakeOf;
    address[] internal vaults;

    uint256 public paid;
    uint256 public fairPaid;
    uint256 public undistributed;

    constructor(Dai _token, Middleware _middleware, VaultManager _vaults) {
        token = _token;
        l1Middleware = _middleware;
        middlewareVaultManager = _vaults;
    }

    function setRewardsShareForAssetClass(uint96 assetClass, uint16 shareBp) external {
        rewardsSharePerAssetClass[assetClass] = shareBp;
    }

    function operatorB() external pure returns (address) {
        return OPERATOR_B;
    }

    function vault2() external pure returns (address) {
        return VAULT2;
    }

    function vault3() external pure returns (address) {
        return VAULT3;
    }

    function staker() external pure returns (address) {
        return STAKER;
    }

    function reclaimer() external pure returns (address) {
        return RECLAIMER;
    }

    function setVaultStake(address vault, uint256 amount) external {
        vaultStakeOf[vault] = amount;
        vaults.push(vault);
    }

    function distribute(uint48 epoch, address operator) external {
        _calculateOperatorShare(epoch, operator);
        _calculateAndStoreVaultShares(epoch, operator);
        _pay(epoch);
    }

    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint96[] memory assetClasses = l1Middleware.getAssetClassIds();
        uint256 totalShare;
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint256 operatorStake = l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClasses[i]);
            uint256 totalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]);
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClasses[i]];

            uint256 shareForClass = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake),
                assetClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            operatorClassShares[epoch][operator][assetClasses[i]] = shareForClass;
            totalShare += shareForClass;
        }
        operatorBeneficiariesShares[epoch][operator] = totalShare;
    }

    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal virtual {}

    function _pay(uint48 epoch) internal {
        uint256 share = vaultShares[epoch][VAULT2];
        paid = Math.mulDiv(share, EPOCH_REWARDS, BASIS_POINTS_DENOMINATOR);
        uint256 classShare = operatorClassShares[epoch][OPERATOR_B][2];
        fairPaid = Math.mulDiv(classShare, EPOCH_REWARDS, BASIS_POINTS_DENOMINATOR);
        token.transfer(STAKER, paid);
        undistributed = fairPaid - paid;
        if (undistributed > 0) token.transfer(RECLAIMER, undistributed);
    }
}

contract Rewards is RewardsBase {
    constructor(Dai _token, Middleware _middleware, VaultManager _vaults) RewardsBase(_token, _middleware, _vaults) {}

    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal override {
        uint256 operatorShare = operatorBeneficiariesShares[epoch][operator];

        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            uint96 vaultAssetClass = middlewareVaultManager.getVaultAssetClass(vault);
            uint256 vaultStake = vaultStakeOf[vault];
            uint256 operatorActiveStake =
                l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, vaultAssetClass);

            uint256 vaultShare = Math.mulDiv(vaultStake, BASIS_POINTS_DENOMINATOR, operatorActiveStake);
            vaultShare = Math.mulDiv(vaultShare, rewardsSharePerAssetClass[vaultAssetClass], BASIS_POINTS_DENOMINATOR);
            // @> VULN: operatorShare is the cross-asset total, not this vault's asset-class share
            vaultShares[epoch][vault] = Math.mulDiv(vaultShare, operatorShare, BASIS_POINTS_DENOMINATOR);
        }
    }
}

contract RewardsFixed is RewardsBase {
    constructor(Dai _token, Middleware _middleware, VaultManager _vaults) RewardsBase(_token, _middleware, _vaults) {}

    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal override {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            uint96 vaultAssetClass = middlewareVaultManager.getVaultAssetClass(vault);
            uint256 vaultStake = vaultStakeOf[vault];
            uint256 operatorActiveStake =
                l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, vaultAssetClass);

            uint256 vaultShare = Math.mulDiv(vaultStake, BASIS_POINTS_DENOMINATOR, operatorActiveStake);
            uint256 classShare = operatorClassShares[epoch][operator][vaultAssetClass];
            vaultShare = Math.mulDiv(vaultShare, classShare, BASIS_POINTS_DENOMINATOR);
            vaultShares[epoch][vault] = vaultShare;
        }
    }
}

contract Exploit {
    Dai public token;
    Middleware public middleware;
    VaultManager public vaultManager;
    Rewards public rewards;

    constructor() {
        token = new Dai();
        middleware = new Middleware();
        vaultManager = new VaultManager();
        rewards = new Rewards(token, middleware, vaultManager);
    }

    function run() external {
        middleware.setAssetClasses(1, 2, 3);
        rewards.setRewardsShareForAssetClass(1, 5000);
        rewards.setRewardsShareForAssetClass(2, 2000);
        rewards.setRewardsShareForAssetClass(3, 3000);

        middleware.setTotalStake(1, 1, 1000);
        middleware.setTotalStake(1, 2, 100);
        middleware.setTotalStake(1, 3, 100);
        middleware.setOperatorStake(1, rewards.operatorB(), 1, 700);
        middleware.setOperatorStake(1, rewards.operatorB(), 2, 100);
        middleware.setOperatorStake(1, rewards.operatorB(), 3, 100);

        vaultManager.setVaultAssetClass(rewards.vault2(), 2);
        vaultManager.setVaultAssetClass(rewards.vault3(), 3);
        rewards.setVaultStake(rewards.vault2(), 100);
        rewards.setVaultStake(rewards.vault3(), 100);

        token.mint(address(rewards), rewards.EPOCH_REWARDS());
        rewards.distribute(1, rewards.operatorB());

        require(rewards.operatorBeneficiariesShares(1, rewards.operatorB()) == 8500, "cross-asset total");
        require(rewards.vaultShares(1, rewards.vault2()) == 1700, "vault2 share");
        require(rewards.paid() == 17_000e18, "paid");
        require(rewards.fairPaid() == 20_000e18, "fair");
        require(rewards.undistributed() == 3_000e18, "leak");
        require(token.balanceOf(rewards.staker()) == 17_000e18, "staker");
        require(token.balanceOf(rewards.reclaimer()) == 3_000e18, "reclaimed");
        require(rewards.paid() != rewards.fairPaid(), "paid matches fair");
    }
}
