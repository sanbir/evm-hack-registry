// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.27;

import {BaseStrategy, StrategyParams, SafeERC20, IERC20} from "contracts/BaseStrategy.sol";
import {Math} from "contracts/utils/math/Math.sol";
import {IVault} from "contracts/interfaces/IVault.sol";

contract StrategyRouterV3 is BaseStrategy {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    /// @notice The V3 yVault we are routing this strategy to.
    IVault public yVault;

    /// @notice Max percentage loss we will take, in basis points (100% = 10_000). Default setting is zero.
    uint256 public maxLoss;

    /// @notice Amount we accept as a loss in liquidatePosition if we don't get 100% back due to rounding errors.
    uint256 public dustThreshold;

    /// @notice Will only be true on the original deployed contract and not on clones; we don't want to clone a clone.
    bool public isOriginal = true;

    // Do I really need to explain this one?
    string internal strategyName;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName
    ) BaseStrategy(_vault) {
        _initializeThis(_yVault, _strategyName);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    /// @notice Use this to clone an exact copy of this strategy on another vault.
    /// @param _vault Vault address we want to attach our new strategy to.
    /// @param _strategist Address to grant the strategist role.
    /// @param _rewards If we have any strategist rewards, send them here.
    /// @param _keeper Address to grant the keeper role.
    /// @param _yVault The newer vault we will route our funds to.
    /// @param _strategyName Name to use for our new strategy.
    function cloneRouterStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        string memory _strategyName
    ) external virtual returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyRouterV3(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _yVault,
            _strategyName
        );

        emit Cloned(newStrategy);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        string memory _strategyName
    ) public {
        require(address(yVault) == address(0));
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeThis(_yVault, _strategyName);
    }

    function _initializeThis(address _yVault, string memory _strategyName)
        internal
    {
        require(IVault(_yVault).asset() == address(want), "wrong want");
        yVault = IVault(_yVault);
        strategyName = _strategyName;
        dustThreshold = 10;
        want.safeApprove(_yVault, type(uint256).max);
    }

    /* ========== VIEWS ========== */

    /// @notice Strategy name.
    function name() external view override returns (string memory) {
        return strategyName;
    }

    /// @notice Total assets the strategy holds, sum of loose and staked want.
    function estimatedTotalAssets()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return balanceOfWant() + valueOfInvestment();
    }

    /// @notice Assets delegated to another vault. Helps to avoid double-counting of TVL.
    /// @dev While a strategy may have loose want, only donations would be unaccounted for, and thus are not counted here.
    ///  Note that a strategy could also have loose want from a manual withdrawFromYVault() call.
    function delegatedAssets() public view override returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    /// @notice Balance of want sitting in our strategy.
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @notice Balance of V3 vault sitting in our strategy.
    function balanceOfVault() public view returns (uint256) {
        return yVault.balanceOf(address(this));
    }

    /// @notice Balance of underlying we are holding as vault tokens of our delegated vault.
    function valueOfInvestment() public view returns (uint256) {
        return yVault.convertToAssets(balanceOfVault());
    }

    /// @notice Balance of underlying we will gain on our next harvest
    function claimableProfits() external view returns (uint256 profits) {
        uint256 assets = estimatedTotalAssets();
        uint256 debt = delegatedAssets();

        if (assets > debt) {
            unchecked {
                profits = assets - debt;
            }
        } else {
            profits = 0;
        }
    }

    /* ========== CORE STRATEGY FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // serious loss should never happen, but if it does, let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = delegatedAssets();

        // if assets are greater than debt, things are working great!
        if (assets >= debt) {
            unchecked {
                _profit = assets - debt;
            }
            _debtPayment = _debtOutstanding;

            uint256 toFree = _profit + _debtPayment;

            // freed is math.min(wantBalance, toFree)
            (uint256 freed, ) = liquidatePosition(toFree);

            if (toFree > freed) {
                if (_debtPayment >= freed) {
                    _debtPayment = freed;
                    _profit = 0;
                } else {
                    unchecked {
                        _profit = freed - _debtPayment;
                    }
                }
            }
        }
        // if assets are less than debt, we are in trouble. don't worry about withdrawing here, just report losses
        else {
            unchecked {
                _loss = debt - assets;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding)
        internal
        virtual
        override
    {
        if (emergencyExit) {
            return;
        }

        uint256 toDeploy =
            Math.min(balanceOfWant(), yVault.maxDeposit(address(this)));

        if (toDeploy > dustThreshold) {
            yVault.deposit(toDeploy, address(this));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 toWithdraw;
        unchecked {
            toWithdraw = _amountNeeded - balance;
        }

        // withdraw the remainder we need
        _withdrawFromYVault(toWithdraw);

        uint256 looseWant = balanceOfWant();

        // because of slippage, dust-sized losses are acceptable
        // however, we don't want to take losses for funds stuck in a strategy in the destination vault
        if (_amountNeeded > looseWant) {
            uint256 diff = _amountNeeded - looseWant;
            _liquidatedAmount = looseWant;
            if (diff < dustThreshold) {
                _loss = diff;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    /// @notice Manually withdraw underlying assets from our target vault.
    /// @dev Only governance or management may call this.
    /// @param _amount Shares of our target vault to withdraw.
    function withdrawFromYVault(uint256 _amount) external onlyVaultManagers {
        _withdrawFromYVault(_amount);
    }

    function _withdrawFromYVault(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        uint256 sharesToWithdraw =
            Math.min(yVault.previewWithdraw(_amount), balanceOfVault());

        if (sharesToWithdraw == 0) {
            return;
        }

        yVault.redeem(sharesToWithdraw, address(this), address(this), maxLoss);
    }

    function liquidateAllPositions()
        internal
        virtual
        override
        returns (uint256 _amountFreed)
    {
        // withdraw as much as we can from vault tokens
        uint256 vaultTokenBalance = balanceOfVault();
        if (vaultTokenBalance > 0) {
            yVault.redeem(
                vaultTokenBalance,
                address(this),
                address(this),
                maxLoss
            );
        }

        // return our want balance
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal virtual override {
        uint256 vaultTokenBalance = balanceOfVault();
        if (vaultTokenBalance > 0) {
            IERC20(yVault).safeTransfer(_newStrategy, vaultTokenBalance);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory ret)
    {}

    /// @notice Convert our keeper's eth cost into want
    /// @dev We don't use this since we don't factor call cost into our harvestTrigger.
    /// @param _amtInWei Amount of ether spent.
    /// @return Value of ether in want.
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {}

    /* ========== SETTERS ========== */
    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    /// @notice Set the maximum loss we will accept (due to slippage or locked funds) on a vault withdrawal.
    /// @dev Generally, this should be zero, and this function will only be used in special/emergency cases.
    /// @param _maxLoss Max percentage loss we will take, in basis points (100% = 10_000).
    function setMaxLoss(uint256 _maxLoss) public onlyVaultManagers {
        require(_maxLoss <= 10_000, "!bps");
        maxLoss = _maxLoss;
    }

    /// @notice This allows us to set the dust threshold for our strategy.
    /// @param _dustThreshold This sets what dust is. If we have less than this remaining after withdrawing, accept it as a loss.
    function setDustThreshold(uint256 _dustThreshold)
        external
        onlyVaultManagers
    {
        require(_dustThreshold < 1e6, "Your size is too much size");
        dustThreshold = _dustThreshold;
    }
}
