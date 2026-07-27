// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {Syndicate} from "../src/syndicate/Syndicate.sol";
import {IStakeHouseUniverse, ISlotRegistry} from "../src/stakehouse-api/contracts/StakehouseAPI.sol";

/// @dev The audited contract only needs these registry calls to establish a
/// valid KNOT and to locate the real sETH token. They are protocol-boundary
/// doubles; the reward and unstake accounting remains the historical source.
contract StakehouseUniverseDouble is IStakeHouseUniverse {
    address public immutable house = address(0xBEEF);

    function stakeHouseKnotInfo(bytes calldata)
        external
        view
        returns (address, uint256, uint256, uint256, uint256, bool)
    {
        return (house, 0, 0, 0, 0, true);
    }
}

contract SlotRegistryDouble is ISlotRegistry {
    address public immutable token;
    address public immutable owner;

    constructor(address token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function stakeHouseShareTokens(address) external view returns (address) { return token; }
    function currentSlashedAmountOfSLOTForKnot(bytes calldata) external pure returns (uint256) { return 0; }
    function numberOfCollateralisedSlotOwnersForKnot(bytes calldata) external pure returns (uint256) { return 1; }
    function getCollateralisedOwnerAtIndex(bytes calldata, uint256) external view returns (address) { return owner; }
    function totalUserCollateralisedSLOTBalanceForKnot(address, address, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return 4 ether;
    }
}

contract StakehouseShareTokenDouble {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Direct initialization is not possible on the implementation because
/// its constructor consumes OpenZeppelin's initializer. The production proxy
/// calls the same internal initializer; this test-only entry point exposes it
/// without changing the audited state transitions.
contract TestableSyndicate is Syndicate {
    function initializeForTest(
        address owner_,
        uint256 priorityEnd,
        address[] memory priorityStakers,
        bytes[] memory keys
    ) external {
        _initialize(owner_, priorityEnd, priorityStakers, keys);
    }
}

contract PoC_43027_StaleClaimSnapshot is Test {
    bytes internal constant KNOT = hex"0102030405";
    uint256 internal constant STAKE = 4 ether;

    StakehouseShareTokenDouble internal sETH;
    TestableSyndicate internal syndicate;

    receive() external payable {}

    function setUp() public {
        sETH = new StakehouseShareTokenDouble();
        StakehouseUniverseDouble universe = new StakehouseUniverseDouble();
        SlotRegistryDouble registry = new SlotRegistryDouble(address(sETH), address(this));

        syndicate = new TestableSyndicate();
        syndicate.configureStakehouseAPI(universe, registry);

        bytes[] memory keys = new bytes[](1);
        keys[0] = KNOT;
        syndicate.initializeForTest(address(this), 0, new address[](0), keys);

        sETH.mint(address(this), STAKE);
        sETH.approve(address(syndicate), STAKE);
        syndicate.stake(keys, _amounts(STAKE), address(this));
    }

    function testPartialUnstakeLeavesStaleClaimAndReverts() public {
        // 8 ETH arrives; the free-floating half is 4 ETH, so the 4-share
        // staker is entitled to a 4 ETH claim before reducing the position.
        vm.deal(address(syndicate), 8 ether);

        bytes[] memory keys = new bytes[](1);
        keys[0] = KNOT;
        syndicate.unstake(address(this), address(this), keys, _amounts(2 ether));

        assertEq(syndicate.sETHStakedBalanceForKnot(KNOT, address(this)), 2 ether);
        assertEq(syndicate.sETHUserClaimForKnot(KNOT, address(this)), 4 ether);
        assertEq(sETH.balanceOf(address(this)), 2 ether);

        // The stale 4 ETH snapshot is subtracted from the remaining 2-share
        // entitlement. Solidity 0.8 arithmetic therefore reverts in the real
        // calculateUnclaimedFreeFloatingETHShare path.
        vm.expectRevert();
        syndicate.calculateUnclaimedFreeFloatingETHShare(KNOT, address(this));
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
